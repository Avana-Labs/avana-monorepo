// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {FlashLiquidator} from "../../src/periphery/flash-liquidator/FlashLiquidator.sol";
import {IFlashLiquidatorErrors} from "../../src/periphery/flash-liquidator/IFlashLiquidatorErrors.sol";
import {OperatorFlashLiquidator} from "../../src/periphery/flash-liquidator/OperatorFlashLiquidator.sol";
import {FlashLiquidationRequest} from "../../src/periphery/flash-liquidator/types/FlashLiquidationRequest.sol";
import {FlashLiquidatorFixture} from "../utils/fixtures/FlashLiquidatorFixture.sol";
import {MockGhoFlashMinter} from "../utils/mocks/MockGhoFlashMinter.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";

/// @notice GHO-debt liquidations through the flash liquidation helper (2.11 `REQ-HELPER-015`): GHO is borrowed from the
/// chain's GHO flash minter (ERC-3156), every other asset from the Aave V3 Pool; the fee is read live from the minter
/// and held to `maxFlashFeeBps` and the caller's `maxPremium`; the callback binds the minter, the initiator, the token,
/// the amount and the context as strictly as the Pool's; a minter recorded as a Hub is refused; a chain without a
/// minter lends GHO from the Pool. The 2.11 example in GHO: `D = 1,950`, `R = 2,040.3`, `A = 19.5` GHO, 5 bps fee.
/// @dev Calls of one test share a transaction (`isolate = false`).
/// forge-config: default.isolate = false
contract FlashLiquidatorGhoUnitTest is FlashLiquidatorFixture {
    uint256 internal constant D_GHO = 1950e18;
    uint256 internal constant FEE_GHO = 0.975e18;
    uint256 internal constant PAYOUT_GHO = 69.825e18;

    function setUp() public {
        _deployHelpers();
        lvs.setDebtAsset(ghoToken);
        lvs.setOutcome(D_GHO, 2040.3e18, 19.5e18);
    }

    function _ghoRequest(
        uint256 x,
        uint256 f,
        uint256 maxPremium,
        uint256 minPayout
    ) internal view returns (FlashLiquidationRequest memory r) {
        r = _request(x, f, maxPremium, 0, minPayout);
        r.params.debtReserveId = GHO_RESERVE;
    }

    function _example() internal view returns (FlashLiquidationRequest memory) {
        return _ghoRequest(D_GHO, D_GHO, FEE_GHO, 69e18);
    }

    function _assertGhoClean(
        address h
    ) internal view {
        assertEq(ghoToken.balanceOf(h), 0, "helper holds GHO");
        assertEq(ghoToken.allowance(h, address(ghoMinter)), 0, "minter allowance left");
        assertEq(ghoToken.allowance(h, address(lvs)), 0, "LPVaultSwap allowance left");
    }

    /// @notice The GHO example borrows from the minter, never the Pool: fee 0.975 GHO (5 bps, half up), payout 69.825
    /// GHO, the minter pulls F + fee and nothing stays in the helper.
    // TEST-292 verifies: REQ-HELPER-015, REQ-HELPER-004, REQ-HELPER-006, REQ-HELPER-007, REQ-HELPER-008, REQ-FLASH-010
    function test_TEST_292_ghoBorrowedFromFlashMinter() public {
        vm.prank(caller);
        uint256 payout = helper.flashLiquidate(_example());
        assertEq(payout, PAYOUT_GHO);
        assertEq(ghoToken.balanceOf(caller), PAYOUT_GHO);
        assertEq(ghoMinter.flashLoanCalls(), 1, "GHO lent by the minter");
        assertEq(aavePool.flashLoanCalls(), 0, "never by the Pool");
        assertEq(ghoMinter.burned(), D_GHO, "principal returned and burned");
        assertEq(ghoToken.balanceOf(address(ghoMinter)), D_GHO + FEE_GHO, "minter pulled F + fee");
        assertEq(lvs.lastCaller(), address(helper));
        _assertGhoClean(address(helper));

        // USDC in the same transaction still goes to the Pool.
        lvs.setDebtAsset(usdcToken);
        lvs.setOutcome(D_EXAMPLE, R_EXAMPLE, A_EXAMPLE);
        vm.prank(caller);
        helper.flashLiquidate(_exampleRequest());
        assertEq(aavePool.flashLoanCalls(), 1);
        assertEq(ghoMinter.flashLoanCalls(), 1);
    }

    /// @notice Quotes for GHO come from the minter, live: what it can mint (capacity less level) and the fee it charges
    /// the helper, 0 once the helper holds `FLASH_BORROWER`.
    // TEST-292 verifies: REQ-HELPER-009, REQ-HELPER-015, REQ-HELPER-003
    function test_TEST_292_ghoQuotesReadLiveFromMinter() public {
        assertEq(helper.maxFlashLoan(address(ghoToken)), GHO_BUCKET);
        assertEq(helper.flashPremium(address(ghoToken), D_GHO), FEE_GHO);
        ghoMinter.setBucket(GHO_BUCKET, GHO_BUCKET - 1000e18);
        assertEq(helper.maxFlashLoan(address(ghoToken)), 1000e18);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.InsufficientFlashLiquidity.selector, 1000e18));
        helper.flashLiquidate(_example());
        ghoMinter.setBucket(GHO_BUCKET, 0);
        acl.addFlashBorrower(address(helper));
        assertEq(helper.flashPremium(address(ghoToken), D_GHO), 0, "FLASH_BORROWER pays no fee");
        vm.prank(caller);
        assertEq(helper.flashLiquidate(_example()), PAYOUT_GHO + FEE_GHO);
    }

    /// @notice The minter's fee is held to `maxFlashFeeBps` (launch 10) before the loan and in the callback, and to
    /// the caller's `maxPremium` in the callback.
    // TEST-292 verifies: REQ-HELPER-005, REQ-HELPER-015, SPEC-LIQ-015, Q-135
    function test_TEST_292_ghoFeeHeldToCapAndMaxPremium() public {
        ghoMinter.setFee(20);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.FlashFeeTooHigh.selector, 3.9e18, 1.95e18));
        helper.flashLiquidate(_example());

        ghoMinter.setFee(MINTER_FEE_BPS);
        ghoMinter.setFeeOverride(2e18);
        FlashLiquidationRequest memory r = _example();
        r.maxPremium = 3e18;
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.FlashFeeTooHigh.selector, 2e18, 1.95e18));
        helper.flashLiquidate(r);

        ghoMinter.setFeeOverride(1e18);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.PremiumTooHigh.selector, 1e18, FEE_GHO));
        helper.flashLiquidate(_example());
    }

    /// @notice For every fee the minter charges and every `maxPremium`, a completed GHO call was charged within both
    /// bounds and paid the caller `keeperOut - F - fee`.
    // TEST-292 verifies: REQ-HELPER-005, REQ-HELPER-008, REQ-HELPER-015, SPEC-LIQ-015
    function testFuzz_TEST_292_ghoChargedFeeWithinBounds(
        uint64 fee,
        uint64 maxPremium
    ) public {
        ghoMinter.setFeeOverride(fee);
        FlashLiquidationRequest memory r = _ghoRequest(D_GHO, D_GHO, maxPremium, 0);
        vm.prank(caller);
        try helper.flashLiquidate(r) returns (uint256 payout) {
            assertLe(fee, maxPremium);
            assertLe(uint256(fee) * 10_000, 10 * D_GHO);
            assertEq(payout, 2020.8e18 - D_GHO - fee);
            _assertGhoClean(address(helper));
        } catch {}
    }

    /// @notice The minter's callback is bound as strictly as the Pool's: outside a context, from another address, with
    /// another initiator, token or amount, or a second time, it reverts `InvalidFlashCallback`; a minter that skips
    /// the callback cannot be repaid.
    // TEST-292 verifies: REQ-HELPER-005, REQ-HELPER-013, REQ-HELPER-015, INV-040
    function test_TEST_292_ghoCallbackBinding() public {
        bytes memory data = abi.encode(_example().params);
        vm.prank(address(ghoMinter));
        vm.expectRevert(IFlashLiquidatorErrors.InvalidFlashCallback.selector);
        helper.onFlashLoan(address(helper), address(ghoToken), D_GHO, FEE_GHO, data);
        vm.expectRevert(IFlashLiquidatorErrors.InvalidFlashCallback.selector);
        helper.onFlashLoan(address(helper), address(ghoToken), D_GHO, FEE_GHO, data);

        ghoMinter.setInitiatorOverride(makeAddr("thirdParty"));
        _expectCallbackRevert();
        ghoMinter.setInitiatorOverride(address(0));
        ghoMinter.setTokenOverride(address(usdcToken));
        _expectCallbackRevert();
        ghoMinter.setTokenOverride(address(0));
        ghoMinter.setAmountBumped(true);
        _expectCallbackRevert();
        ghoMinter.setAmountBumped(false);
        ghoMinter.setCallbackTwice(true);
        _expectCallbackRevert();
        ghoMinter.setCallbackTwice(false);
        ghoMinter.setSkipCallback(true);
        vm.prank(caller);
        vm.expectRevert();
        helper.flashLiquidate(_example());
        ghoMinter.setSkipCallback(false);

        // After every refused attempt an honest call settles and leaves nothing behind.
        vm.prank(caller);
        helper.flashLiquidate(_example());
        _assertGhoClean(address(helper));
    }

    /// @notice A third party's minter loan naming the helper as receiver carries the third party as initiator.
    // TEST-292 verifies: REQ-HELPER-005, REQ-HELPER-015, INV-040
    function test_TEST_292_thirdPartyMinterLoanToHelperReverts() public {
        vm.prank(makeAddr("thirdParty"));
        vm.expectRevert(IFlashLiquidatorErrors.InvalidFlashCallback.selector);
        ghoMinter.flashLoan(address(helper), address(ghoToken), D_GHO, abi.encode(_example().params));
    }

    /// @notice A minter recorded as a Hub is refused at deployment even with a Pool that is no Hub.
    // TEST-292 verifies: REQ-HELPER-002, REQ-HELPER-015
    function test_TEST_292_minterRecordedAsHubRefusedAtDeployment() public {
        registry.setHub(address(ghoMinter), true);
        vm.expectRevert(IFlashLiquidatorErrors.FlashSourceIsHub.selector);
        new FlashLiquidator(address(aavePool), address(lvs), address(registry), address(store), address(ghoMinter));
    }

    /// @notice A minter whose `flashLoan` returns false fails the call with `InvalidFlashCallback`: nothing settles,
    /// the caller is paid nothing and the helper keeps no GHO, allowance or context.
    // TEST-292 verifies: REQ-HELPER-004, REQ-HELPER-015
    function test_TEST_292_minterReturningFalseReverts() public {
        uint256 callerBefore = ghoToken.balanceOf(caller);
        vm.mockCall(address(ghoMinter), abi.encodeWithSelector(ghoMinter.flashLoan.selector), abi.encode(false));
        vm.prank(caller);
        vm.expectRevert(IFlashLiquidatorErrors.InvalidFlashCallback.selector);
        helper.flashLiquidate(_example());
        vm.clearMockedCalls();
        assertEq(ghoToken.balanceOf(caller), callerBefore, "caller unchanged");
        _assertGhoClean(address(helper));
        // The context did not survive the revert: an honest call settles next.
        vm.prank(caller);
        assertEq(helper.flashLiquidate(_example()), PAYOUT_GHO);
    }

    /// @notice A minter recorded as a Hub is refused at deployment and on every GHO call, while other assets keep the
    /// Pool; a minter that names no GHO is refused at deployment.
    // TEST-292 verifies: REQ-HELPER-002, REQ-HELPER-013, REQ-HELPER-015, INV-095
    function test_TEST_292_minterHubRuleAndZeroGho() public {
        MockGhoFlashMinter noGho = new MockGhoFlashMinter(PayoutToken(address(0)), acl, 5, GHO_BUCKET);
        vm.expectRevert(IFlashLiquidatorErrors.ZeroAddress.selector);
        new FlashLiquidator(address(aavePool), address(lvs), address(registry), address(store), address(noGho));

        registry.setHub(address(ghoMinter), true);
        vm.expectRevert(IFlashLiquidatorErrors.FlashSourceIsHub.selector);
        new FlashLiquidator(address(aavePool), address(lvs), address(registry), address(store), address(ghoMinter));
        vm.prank(caller);
        vm.expectRevert(IFlashLiquidatorErrors.FlashSourceIsHub.selector);
        helper.flashLiquidate(_example());
        assertEq(ghoMinter.flashLoanCalls(), 0);

        lvs.setDebtAsset(usdcToken);
        lvs.setOutcome(D_EXAMPLE, R_EXAMPLE, A_EXAMPLE);
        vm.prank(caller);
        assertEq(helper.flashLiquidate(_exampleRequest()), 69.825e6, "USDC still borrows from the Pool");
    }

    /// @notice On a chain whose GHO has no flash minter the helper lends GHO from the Pool like any asset; with no GHO
    /// reserve in the Pool it reverts `InsufficientFlashLiquidity(0)` before any state change.
    // TEST-292 verifies: REQ-HELPER-015, REQ-HELPER-003, REQ-HELPER-009, REQ-FLASH-010
    function test_TEST_292_noMinterLendsGhoFromPool() public {
        FlashLiquidator noMinter =
            new FlashLiquidator(address(aavePool), address(lvs), address(registry), address(store), address(0));
        assertEq(noMinter.maxFlashLoan(address(ghoToken)), 0);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.InsufficientFlashLiquidity.selector, 0));
        noMinter.flashLiquidate(_example());
    }

    /// @notice The operator variant applies its loan and outlay bounds to GHO loans too: a loan above
    /// `ceil(D x 1.05)` is refused, and an honest one pays the Safe.
    // TEST-292 verifies: REQ-HELPER-011, REQ-HELPER-015
    function test_TEST_292_operatorGhoBounds() public {
        uint256 x = 10_000e18;
        FlashLiquidationRequest memory r = _ghoRequest(x, x, 5e18, 0);
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.FlashAmountAboveNeed.selector, x, 2047.5e18));
        opHelper.flashLiquidate(r);
        vm.prank(signer);
        assertEq(opHelper.flashLiquidate(_example()), PAYOUT_GHO);
        assertEq(ghoToken.balanceOf(safe), PAYOUT_GHO);
        _assertGhoClean(address(opHelper));
    }

    function _expectCallbackRevert() internal {
        vm.prank(caller);
        vm.expectRevert(IFlashLiquidatorErrors.InvalidFlashCallback.selector);
        helper.flashLiquidate(_example());
    }
}
