// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {IFlashLiquidatorErrors} from "../../src/periphery/flash-liquidator/IFlashLiquidatorErrors.sol";
import {IOperatorFlashLiquidator} from "../../src/periphery/flash-liquidator/IOperatorFlashLiquidator.sol";
import {OperatorFlashLiquidator} from "../../src/periphery/flash-liquidator/OperatorFlashLiquidator.sol";
import {FlashLiquidationRequest} from "../../src/periphery/flash-liquidator/types/FlashLiquidationRequest.sol";
import {FlashLiquidatorFixture} from "../utils/fixtures/FlashLiquidatorFixture.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";

/// @notice How a helper call is funded (2.11 `REQ-HELPER-004`, `-006`, `-007`, `-010`, `-011`): the `SPEC-LIQ-019`
/// floor shortfall is paid through the helper from the payer's `maxShortfall` budget; the operator Safe's net outlay
/// per call is bounded by `MAX_TOP_UP_BPS` of the debt LPVaultSwap repaid, and its loan by what that debt needed; the
/// public helper's escrowed credits are claimable by anyone to `feeRecipient`. Regression tests of the 2026-11-11
/// review findings FL-01, FL-02 and FL-03.
contract FlashLiquidatorFundingUnitTest is FlashLiquidatorFixture {
    /// @dev SPEC-LIQ-019 example: V = 12,422.6 USDC, s = 100 bps, minRec = 12,297.373998 USDC, routes return 12,174.
    uint256 internal constant X_FLOOR = 12_000e6;
    uint256 internal constant MIN_REC = 12_297.373998e6;
    uint256 internal constant R_FLOOR = 12_174e6;
    uint256 internal constant SHORTFALL = 123.373998e6;

    function setUp() public {
        _deployHelpers();
    }

    function _floorRequest(
        uint256 flashAmount,
        uint256 maxShortfall
    ) internal view returns (FlashLiquidationRequest memory r) {
        r = _request(X_FLOOR, flashAmount, 6e6, 0, 0);
        r.params.maxShortfall = maxShortfall;
    }

    function _assertHelperEmpty(
        address h
    ) internal view {
        assertEq(usdcToken.balanceOf(h), 0, "helper holds no debt asset");
        assertEq(usdcToken.allowance(h, address(lvs)), 0, "no LPVaultSwap allowance");
        assertEq(usdcToken.allowance(h, address(aavePool)), 0, "no Pool allowance");
    }

    // ─── FL-01: the SPEC-LIQ-019 shortfall through the helper ───

    /// @notice The SPEC-LIQ-019 example through the public helper with the whole X borrowed: the helper pulls the
    /// caller's 200 USDC shortfall budget, LPVaultSwap pulls X and then the 123.373998 USDC floor gap, and the unused
    /// 76.626002 USDC returns in the payout. payout = keeperOut + unused - F - premium = 12,297.373998 + 76.626002 -
    /// 12,006 = 368 USDC; the caller's net result is 368 - 200 = 168 = R - D - premium.
    // TEST-174 verifies: REQ-HELPER-004, REQ-HELPER-006, REQ-HELPER-007, REQ-HELPER-008, SPEC-LIQ-019, REQ-SWAP-011
    function test_TEST_174_helperPaysTheFloorShortfallFromThePayer() public {
        lvs.setOutcome(X_FLOOR, R_FLOOR, 0);
        lvs.setFloor(MIN_REC);
        _fund(keeper, address(helper), 200e6);
        vm.prank(keeper);
        uint256 payout = helper.flashLiquidate(_floorRequest(X_FLOOR, 200e6));
        assertEq(lvs.lastShortfall(), SHORTFALL, "LPVaultSwap pulled the floor gap from the helper");
        assertEq(lvs.lastKeeperOut(), MIN_REC, "keeperOut = Kf + R + shortfall - D");
        assertEq(payout, 368e6);
        assertEq(usdcToken.balanceOf(keeper), 368e6, "net 168 USDC after the 200 USDC budget");
        _assertHelperEmpty(address(helper));
    }

    /// @notice The same liquidation with only 1 USDC borrowed: the caller funds X - F = 11,999 USDC and the 200 USDC
    /// budget; its net result is R - D - premium(1 USDC) = 174 - 0.0005 USDC.
    // TEST-174 verifies: REQ-HELPER-004, REQ-HELPER-006, REQ-HELPER-008, SPEC-LIQ-019
    function test_TEST_174_helperShortfallWithInventory() public {
        lvs.setOutcome(X_FLOOR, R_FLOOR, 0);
        lvs.setFloor(MIN_REC);
        uint256 pulled = X_FLOOR - 1e6 + 200e6;
        _fund(keeper, address(helper), pulled);
        FlashLiquidationRequest memory r = _floorRequest(1e6, 200e6);
        r.maxPremium = 500;
        vm.prank(keeper);
        uint256 payout = helper.flashLiquidate(r);
        assertEq(lvs.lastShortfall(), SHORTFALL);
        assertEq(payout, pulled + 174e6 - 500);
        _assertHelperEmpty(address(helper));
    }

    /// @notice A floor gap above the caller's budget reverts inside LPVaultSwap (`RecoveryBelowFloor`), and the whole
    /// call with it; a budget the call does not need returns whole in the payout.
    // TEST-174 verifies: REQ-HELPER-006, REQ-HELPER-008, SPEC-LIQ-019
    function test_TEST_174_helperShortfallBudgetBoundsAndReturns() public {
        lvs.setOutcome(X_FLOOR, R_FLOOR, 0);
        lvs.setFloor(MIN_REC);
        _fund(keeper, address(helper), 100e6);
        FlashLiquidationRequest memory r = _floorRequest(X_FLOOR, 100e6);
        vm.prank(keeper);
        vm.expectRevert(ILPVaultSwapErrors.RecoveryBelowFloor.selector);
        helper.flashLiquidate(r);

        // The 2.11 example recovers above its floor: the 50 USDC budget is untouched and paid back.
        lvs.setOutcome(D_EXAMPLE, R_EXAMPLE, A_EXAMPLE);
        lvs.setFloor(0);
        FlashLiquidationRequest memory e = _exampleRequest();
        e.params.maxShortfall = 50e6;
        _fund(caller, address(helper), 50e6);
        vm.prank(caller);
        uint256 payout = helper.flashLiquidate(e);
        assertEq(payout, 69.825e6 + 50e6);
        assertEq(usdcToken.balanceOf(caller), 69.825e6 + 50e6);
        _assertHelperEmpty(address(helper));
    }

    /// @notice A shortfall budget covers the loan repayment before any top-up is pulled: with R = 1,950, the routed
    /// example owes 0.975 USDC of premium beyond keeperOut, which the unused 5 USDC budget pays.
    // TEST-174 verifies: REQ-HELPER-007, REQ-HELPER-008
    function test_TEST_174_unusedShortfallBudgetRepaysBeforeTopUp() public {
        lvs.setOutcome(D_EXAMPLE, D_EXAMPLE, 0);
        FlashLiquidationRequest memory r = _request(D_EXAMPLE, D_EXAMPLE, 975_000, 0, 0);
        r.params.maxShortfall = 5e6;
        _fund(caller, address(helper), 5e6);
        vm.prank(caller);
        uint256 payout = helper.flashLiquidate(r);
        assertEq(payout, 5e6 - 975_000, "no top-up; the budget paid the premium");
        _assertHelperEmpty(address(helper));
    }

    // ─── FL-02: the operator Safe's outlay is bounded by the debt repaid ───

    /// @notice Review PoC: with top-ups disabled, a compromised signer borrowed `X - 5,000` USDC of a 10,000,000 USDC
    /// `debtToCover` against Bob's 1,950 USDC debt, so the Safe's 5,000 USDC inventory paid a 4,997.5 USDC premium and
    /// lost 4,926.7 USDC. The loan is now refused: it exceeds `ceil(1,950 x 1.05) = 2,047.5` USDC.
    // TEST-174 verifies: REQ-HELPER-011, REQ-HELPER-016
    function test_TEST_174_operatorRefusesLoanAboveNeed() public {
        OperatorFlashLiquidator noTopUp = new OperatorFlashLiquidator(
            address(aavePool), address(lvs), address(registry), address(store), signer, safe, 0
        );
        _fund(safe, address(noTopUp), 10_000e6);
        uint256 x = 10_000_000e6;
        uint256 f = x - 5000e6;
        FlashLiquidationRequest memory r = _request(x, f, 5000e6, 0, 0);
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.FlashAmountAboveNeed.selector, f, 2047.5e6));
        noTopUp.flashLiquidate(r);
        assertEq(usdcToken.balanceOf(safe), 10_000e6, "the Safe keeps its inventory");

        // The fixture helper (100 bps): X = F = 10,000,000 USDC, unlimited maxTopUp, once took 4,929.2 USDC.
        _fund(safe, address(opHelper), 10_000e6);
        r = _request(x, x, 5000e6, type(uint256).max, 0);
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.FlashAmountAboveNeed.selector, x, 2047.5e6));
        opHelper.flashLiquidate(r);

        // The honest sizing (F at most the debt plus the Lens margin) still settles.
        vm.prank(signer);
        assertEq(noTopUp.flashLiquidate(_request(2047.5e6, 2047.5e6, 1_023_750, 0, 0)), 69.77625e6);
    }

    /// @notice The Safe's net outlay (inventory, shortfall budget and top-up, less the payout) is bounded by
    /// `floor(D x MAX_TOP_UP_BPS / 1e4)` = 19.5 USDC for D = 1,950: a recovery of 1,900 loses 50.975 USDC and reverts;
    /// one of 1,940 loses 10.975 USDC and settles.
    // TEST-174 verifies: REQ-HELPER-011, REQ-HELPER-007, REQ-HELPER-016
    function test_TEST_174_operatorOutlayBoundedByDebtRepaid() public {
        _fund(safe, address(opHelper), 97.5e6);
        lvs.setOutcome(D_EXAMPLE, 1900e6, 0);
        FlashLiquidationRequest memory r = _request(2047.5e6, D_EXAMPLE, 975_000, 0, 0);
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.OutlayExceeded.selector, 50.975e6, 19.5e6));
        opHelper.flashLiquidate(r);

        lvs.setOutcome(D_EXAMPLE, 1940e6, 0);
        vm.prank(signer);
        uint256 payout = opHelper.flashLiquidate(r);
        assertEq(payout, 86.525e6);
        assertEq(usdcToken.balanceOf(safe), 86.525e6, "the Safe lost 10.975 USDC, within 19.5");
        _assertHelperEmpty(address(opHelper));
    }

    /// @notice The top-up bound is `MAX_TOP_UP_BPS` of the debt repaid, not of the signer's `debtToCover`: X = F =
    /// 2,047.5 USDC against D = 1,950 needs a 101.02375 USDC top-up, refused at 19.5 USDC (the X-based bound was 20.475).
    // TEST-174 verifies: REQ-HELPER-007, REQ-HELPER-011, REQ-SWAP-081
    function test_TEST_174_operatorTopUpBoundFromDebtRepaid() public {
        _fund(safe, address(opHelper), 1000e6);
        lvs.setOutcome(D_EXAMPLE, 1850e6, 0);
        FlashLiquidationRequest memory r = _request(2047.5e6, 2047.5e6, 1_023_750, type(uint256).max, 0);
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.TopUpExceeded.selector, 101.02375e6, 19.5e6));
        opHelper.flashLiquidate(r);
    }

    /// @notice A floor shortfall through the operator helper is part of the Safe's outlay: SPEC-LIQ-019 example with
    /// D = 12,000 USDC (bound 120 USDC); the call gains R - D - premium = 168 USDC, so the Safe ends 168 USDC up.
    // TEST-174 verifies: REQ-HELPER-006, REQ-HELPER-011, SPEC-LIQ-019
    function test_TEST_174_operatorShortfallWithinOutlay() public {
        lvs.setOutcome(X_FLOOR, R_FLOOR, 0);
        lvs.setFloor(MIN_REC);
        _fund(safe, address(opHelper), 200e6);
        vm.prank(signer);
        uint256 payout = opHelper.flashLiquidate(_floorRequest(X_FLOOR, 200e6));
        assertEq(payout, 368e6);
        assertEq(usdcToken.balanceOf(safe), 368e6);
    }

    /// @notice For every loan, inventory, recovery and shortfall budget, a completed operator call left the Safe at
    /// most `floor(D x MAX_TOP_UP_BPS / 1e4)` poorer in the debt asset, with `F <= ceil(D x 1.05)`.
    // TEST-174 verifies: REQ-HELPER-011, REQ-HELPER-007, REQ-HELPER-008
    function testFuzz_TEST_174_operatorSafeLossBoundedByDebtRepaid(
        uint256 x,
        uint256 f,
        uint256 d,
        uint256 rec,
        uint256 maxShortfall
    ) public {
        x = bound(x, 1e6, 1_000_000e6);
        // F = 0 included: the operator variant then takes no loan (REQ-HELPER-003) under the same bound.
        f = bound(f, 0, x);
        d = bound(d, 1, x);
        rec = bound(rec, 0, 2 * d);
        maxShortfall = bound(maxShortfall, 0, 10_000e6);
        lvs.setOutcome(d, rec, 0);
        _fund(safe, address(opHelper), 2_000_000e6);
        uint256 before = usdcToken.balanceOf(safe);
        FlashLiquidationRequest memory r = _request(x, f, type(uint256).max, type(uint256).max, 0);
        r.params.maxShortfall = maxShortfall;
        vm.prank(signer);
        try opHelper.flashLiquidate(r) {
            uint256 after_ = usdcToken.balanceOf(safe);
            uint256 loss = before > after_ ? before - after_ : 0;
            assertLe(loss, (d * OPERATOR_TOP_UP_BPS) / 10_000, "Safe loss within MAX_TOP_UP_BPS of D");
            assertLe(f, (d * 10_500 + 9999) / 10_000, "loan within the need");
            _assertHelperEmpty(address(opHelper));
        } catch {}
    }

    // ─── FL-03: the public helper's escrowed credits ───

    /// @notice USDT blocks the public helper, so a 0.4 USDT residue is credited to the helper in the PayoutEscrow; the
    /// helper claims the credit its own call created to its caller in the same call (REQ-HELPER-010).
    // TEST-289 verifies: REQ-HELPER-010, REQ-HELPER-008, REQ-SWAP-076, Q-389
    function test_TEST_289_publicHelperCreditGoesToItsCaller() public {
        usdtToken.setBlocked(address(helper), true);
        lvs.addResidue(usdtToken, 0.4e6);
        vm.prank(caller);
        helper.flashLiquidate(_exampleRequest());
        assertEq(escrow.claimable(address(usdtToken), address(helper)), 0, "claimed in the call");
        assertEq(usdtToken.balanceOf(caller), 0.4e6, "the caller's own residue");
        assertEq(usdtToken.balanceOf(feeRecipient), 0, "not Avana's");
    }

    /// @notice When the caller cannot receive the residue either, the claim inside the call fails without failing the
    /// liquidation, the credit stays, and anyone later claims it to `feeRecipient`, read from the ParameterStore as
    /// LPVaultSwap reads it.
    // TEST-289 verifies: REQ-HELPER-010, REQ-SWAP-076, Q-389
    function test_TEST_289_publicHelperCreditClaimedToFeeRecipient() public {
        usdtToken.setBlocked(address(helper), true);
        usdtToken.setBlocked(caller, true);
        lvs.addResidue(usdtToken, 0.4e6);
        vm.prank(caller);
        helper.flashLiquidate(_exampleRequest());
        assertEq(escrow.claimable(address(usdtToken), address(helper)), 0.4e6);

        vm.prank(makeAddr("anyone"));
        uint256 claimed = IOperatorFlashLiquidator(address(helper)).claimEscrowed(address(usdtToken));
        assertEq(claimed, 0.4e6);
        assertEq(usdtToken.balanceOf(feeRecipient), 0.4e6, "credit sent to feeRecipient");
        assertEq(escrow.claimable(address(usdtToken), address(helper)), 0);
    }

    /// @notice While the ParameterStore serves `feeRecipient = address(0)` the public helper's claim reverts
    /// `InvalidFeeRecipient`, as LPVaultSwap does, and the credit stays in the PayoutEscrow.
    // TEST-289 verifies: REQ-HELPER-010, REQ-SWAP-028
    function test_TEST_289_publicHelperClaimRefusesZeroFeeRecipient() public {
        usdtToken.setBlocked(address(helper), true);
        usdtToken.setBlocked(caller, true);
        lvs.addResidue(usdtToken, 0.4e6);
        vm.prank(caller);
        helper.flashLiquidate(_exampleRequest());
        vm.mockCall(address(store), abi.encodeWithSelector(store.feeRecipient.selector), abi.encode(address(0)));
        vm.expectRevert(IFlashLiquidatorErrors.InvalidFeeRecipient.selector);
        IOperatorFlashLiquidator(address(helper)).claimEscrowed(address(usdtToken));
        vm.clearMockedCalls();
        assertEq(escrow.claimable(address(usdtToken), address(helper)), 0.4e6, "credit kept");
        assertEq(usdtToken.balanceOf(feeRecipient), 0);
    }

    /// @notice A debt asset that blocks the public helper stops only liquidations through it: the same liquidation
    /// funded by the caller itself settles.
    // TEST-289 verifies: REQ-HELPER-010, REQ-SWAP-011, REQ-SWAP-026
    function test_TEST_289_debtAssetBlockOnHelperLeavesSelfFundedCalls() public {
        usdcToken.setBlocked(address(helper), true);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(PayoutToken.Blocked.selector, address(helper)));
        helper.flashLiquidate(_exampleRequest());

        _fund(caller, address(lvs), D_EXAMPLE);
        vm.prank(caller);
        lvs.liquidate(_params(D_EXAMPLE));
        assertEq(usdcToken.balanceOf(caller), 2020.8e6, "the caller funded and was paid itself");
    }
}
