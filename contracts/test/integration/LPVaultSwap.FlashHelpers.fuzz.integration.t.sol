// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {FlashLiquidator} from "../../src/periphery/flash-liquidator/FlashLiquidator.sol";
import {IFlashLiquidatorErrors} from "../../src/periphery/flash-liquidator/IFlashLiquidatorErrors.sol";
import {FlashLiquidationRequest} from "../../src/periphery/flash-liquidator/types/FlashLiquidationRequest.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";

/// @title LPVaultSwapFlashHelpersFuzzIntegrationTest
/// @notice The public flash liquidation helper against the real LPVaultSwap fuzzed (2.11 REQ-HELPER-004 to
/// REQ-HELPER-010, REQ-SWAP-012, REQ-SWAP-014): for any repayment `X = F`, Pool premium rate, `maxPremium`,
/// `minPayout` and `FLASH_BORROWER` grant, the helper either pays its caller exactly what the same liquidation funded
/// directly pays (`keeperOut`) less `F + φ`, with the Pool repaid and the helper and LPVaultSwap empty, or reverts with
/// `PremiumTooHigh` or `PayoutTooLow` and nothing moves.
/// forge-config: default.isolate = false
/// forge-config: default.fuzz.runs = 256
contract LPVaultSwapFlashHelpersFuzzIntegrationTest is LPVaultSwapUnitBase {
    FlashLiquidator internal helper;
    address internal proxy;

    function setUp() public override {
        super.setUp();
        helper = new FlashLiquidator(address(v3Pool), address(lvs), address(registry), address(store));
        (proxy,) = _bobAccount();
    }

    function _request(
        uint256 x
    ) internal view returns (FlashLiquidationRequest memory q) {
        q.params = _params(proxy, x);
        q.flashAmount = x;
        q.maxPremium = type(uint128).max;
    }

    /// @notice The helper's payout equals the direct caller's `keeperOut − F − φ` for the same liquidation.
    // TEST-289 verifies: REQ-HELPER-004, REQ-HELPER-006, REQ-HELPER-007, REQ-HELPER-008, REQ-SWAP-012, Q-404
    function testFuzz_TEST_289_helperPaysDirectPayoutLessLoan(
        uint256 x,
        uint256 premiumBps,
        bool borrower
    ) public {
        x = bound(x, 100e6, 6000e6);
        premiumBps = bound(premiumBps, 0, 9);
        v3Pool.setPremiumTotal(uint128(premiumBps));
        if (borrower) acl.addFlashBorrower(address(helper));
        uint256 phi = borrower ? 0 : (x * premiumBps + 5000) / 10_000;
        uint256 snapshot = vm.snapshotState();
        LiquidationResult memory direct = _liquidateAs(keeper, _params(proxy, x));
        vm.revertToState(snapshot);
        address caller = makeAddr("helperCaller");
        uint256 poolBefore = usdc.balanceOf(v3Pool.getReserveAToken(address(usdc)));
        vm.prank(caller);
        uint256 payout = helper.flashLiquidate(_request(x));
        assertEq(payout, direct.keeperOut - x - phi, "payout = keeperOut - F - phi");
        assertEq(usdc.balanceOf(caller), payout, "caller paid");
        assertEq(usdc.balanceOf(v3Pool.getReserveAToken(address(usdc))), poolBefore + phi, "Pool repaid F + phi");
        assertEq(usdc.balanceOf(address(helper)), 0, "helper empty");
        assertEq(usdc.balanceOf(address(lvs)), 0, "LPVaultSwap empty");
        assertEq(usdc.allowance(address(helper), address(lvs)), 0, "no allowance to LPVaultSwap");
    }

    /// @notice `maxPremium` below the Pool's half-up charge reverts `PremiumTooHigh(charge, maxPremium)` before
    /// LPVaultSwap is called; at the charge it settles.
    // TEST-289 verifies: REQ-HELPER-003, REQ-HELPER-009
    function testFuzz_TEST_289_maxPremiumBoundary(
        uint256 x,
        uint256 below
    ) public {
        x = bound(x, 100e6, 6000e6);
        // The bound applies to the Pool's half-up charge; the helper's view quotes its ceiling.
        uint256 quote = (x * 5 + 5000) / 10_000;
        assertGe(helper.flashPremium(address(usdc), x), quote, "the view never quotes below the charge");
        below = bound(below, 1, quote);
        FlashLiquidationRequest memory q = _request(x);
        q.maxPremium = quote - below;
        uint256 burns = adapter.burnCalls();
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.PremiumTooHigh.selector, quote, quote - below));
        helper.flashLiquidate(q);
        assertEq(adapter.burnCalls(), burns, "LPVaultSwap never reached");
        q.maxPremium = quote;
        vm.prank(carol);
        assertGt(helper.flashLiquidate(q), 0, "settles at the quote");
    }

    /// @notice `minPayout` above the payout reverts `PayoutTooLow(payout, minPayout)` after LPVaultSwap returns and
    /// nothing moves; at the payout it settles.
    // TEST-289 verifies: REQ-HELPER-008, REQ-HELPER-014, REQ-SWAP-073
    function testFuzz_TEST_289_minPayoutBoundary(
        uint256 x,
        uint256 extra
    ) public {
        x = bound(x, 100e6, 6000e6);
        extra = bound(extra, 1, 1e12);
        uint256 snapshot = vm.snapshotState();
        vm.prank(carol);
        uint256 payout = helper.flashLiquidate(_request(x));
        vm.revertToState(snapshot);
        FlashLiquidationRequest memory q = _request(x);
        q.minPayout = payout + extra;
        uint256 debt = _debtOf(proxy, usdcReserveId);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.PayoutTooLow.selector, payout, payout + extra));
        helper.flashLiquidate(q);
        assertEq(_debtOf(proxy, usdcReserveId), debt, "nothing repaid");
        q.minPayout = payout;
        vm.prank(carol);
        assertEq(helper.flashLiquidate(q), payout, "settles at the boundary");
    }
}
