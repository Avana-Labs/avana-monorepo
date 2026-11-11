// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashLiquidator} from "../../src/periphery/flash-liquidator/IFlashLiquidator.sol";
import {IFlashLiquidatorErrors} from "../../src/periphery/flash-liquidator/IFlashLiquidatorErrors.sol";
import {FlashLiquidatorFixture} from "../utils/fixtures/FlashLiquidatorFixture.sol";

/// @notice Payout accounting of the flash liquidation helper (2.11 `REQ-HELPER-007`, `REQ-HELPER-008`) over loan size,
/// funding, Aave's repayment, recovery, Avana's fee, the Pool rate, the top-up bound and the net minimum: every call
/// either reverts with the error the inputs predict, before or with the whole liquidation, or pays
/// `payout = keeperOut + topUp − F − φ` to its caller, repays the Pool `F + φ` with `φ` the half-up premium, and leaves
/// the helper with no balance and no allowance.
contract FlashLiquidatorFuzzTest is FlashLiquidatorFixture {
    struct Case {
        uint256 x;
        uint256 f;
        uint256 d;
        uint256 r;
        uint256 a;
        uint256 rate;
        uint256 maxTopUp;
        uint256 minPayout;
    }

    function setUp() public {
        _deployHelpers();
    }

    function _bound(
        Case memory c
    ) internal pure returns (Case memory) {
        c.x = bound(c.x, 1, 10_000_000e6);
        c.f = bound(c.f, 1, c.x);
        c.d = bound(c.d, 1, c.x);
        c.r = bound(c.r, 0, 2 * c.x);
        c.a = bound(c.a, 0, c.x + c.r - c.d);
        c.rate = bound(c.rate, 0, 9);
        c.maxTopUp = bound(c.maxTopUp, 0, 2 * c.x);
        c.minPayout = bound(c.minPayout, 0, 3 * c.x);
        return c;
    }

    // TEST-174 verifies: REQ-HELPER-003, REQ-HELPER-005, REQ-HELPER-006, REQ-HELPER-007, REQ-HELPER-008, REQ-HELPER-014, SPEC-LIQ-015, Q-345, Q-404
    // TEST-288 verifies: REQ-HELPER-001
    // Sources: 5.1 TEST-198 (half-up charge never above the ceiling quote), MATH-ST-115
    function testFuzz_TEST_174_payoutAccounting(
        Case memory c
    ) public {
        c = _bound(c);
        aavePool.setPremiumTotal(uint128(c.rate));
        lvs.setOutcome(c.d, c.r, c.a);
        Expected memory e = _expect(c);
        _fund(caller, address(helper), e.funds);

        vm.prank(caller);
        (bool ok, bytes memory ret) = address(helper)
            .call(
                abi.encodeCall(
                    IFlashLiquidator.flashLiquidate, (_request(c.x, c.f, e.premium, c.maxTopUp, c.minPayout))
                )
            );
        if (e.revertData.length != 0) {
            assertFalse(ok, "expected a revert");
            assertEq(ret, e.revertData);
            assertEq(usdcToken.balanceOf(caller), e.funds, "nothing moved");
            assertEq(lvs.calls(), 0, "the whole liquidation reverted");
        } else {
            assertTrue(ok, "expected success");
            uint256 payout = abi.decode(ret, (uint256));
            assertEq(payout, e.payout, "payout = keeperOut + topUp - F - premium");
            assertGe(payout, c.minPayout);
            assertEq(usdcToken.balanceOf(caller), e.funds - (c.x - c.f) - e.topUp + payout, "caller funds conserved");
            assertEq(usdcToken.balanceOf(aUsdc), IDLE_USDC + e.premium, "Pool repaid F + premium");
            assertEq(usdcToken.balanceOf(treasury), c.a, "Avana's fee untouched by the loan");
            assertLe(e.premium, e.quote, "half-up charge never above the ceiling quote");
        }
        assertEq(usdcToken.balanceOf(address(helper)), 0);
        assertEq(usdcToken.allowance(address(helper), address(aavePool)), 0);
        assertEq(usdcToken.allowance(address(helper), address(lvs)), 0);
    }

    struct Expected {
        uint256 funds;
        uint256 quote;
        uint256 premium;
        uint256 topUp;
        uint256 payout;
        bytes revertData;
    }

    /// @dev The outcome the 2.11 rules predict: the ceiling quote and half-up charge, `keeperOut = X + R − D − A`,
    /// the top-up `F + φ − keeperOut` when positive, the net payout, and the first error that applies.
    function _expect(
        Case memory c
    ) internal pure returns (Expected memory e) {
        e.funds = c.x + c.maxTopUp;
        e.quote = (c.f * c.rate + 9999) / 10_000;
        e.premium = (c.f * c.rate + 5000) / 10_000;
        uint256 keeperOut = c.x + c.r - c.d - c.a;
        uint256 owed = c.f + e.premium;
        e.topUp = keeperOut < owed ? owed - keeperOut : 0;
        e.payout = keeperOut + e.topUp - owed;
        if (e.quote * 10_000 > 10 * c.f) {
            e.revertData =
                abi.encodeWithSelector(IFlashLiquidatorErrors.FlashFeeTooHigh.selector, e.quote, c.f * 10 / 10_000);
        } else if (e.topUp > c.maxTopUp) {
            e.revertData = abi.encodeWithSelector(IFlashLiquidatorErrors.TopUpExceeded.selector, e.topUp, c.maxTopUp);
        } else if (e.payout < c.minPayout) {
            e.revertData = abi.encodeWithSelector(IFlashLiquidatorErrors.PayoutTooLow.selector, e.payout, c.minPayout);
        }
    }

    /// @notice The operator variant pulls a top-up only up to `min(maxTopUp, ⌊X × 100 / 10⁴⌋)`.
    // TEST-174 verifies: REQ-HELPER-007, REQ-HELPER-011, REQ-SWAP-081
    function testFuzz_TEST_174_operatorTopUpBound(
        uint256 x,
        uint256 shortBy,
        uint256 maxTopUp
    ) public {
        x = bound(x, 1, 10_000_000e6);
        shortBy = bound(shortBy, 0, x);
        maxTopUp = bound(maxTopUp, 0, x);
        acl.addFlashBorrower(address(opHelper));
        lvs.setOutcome(x, x - shortBy, 0);
        _fund(safe, address(opHelper), x);
        uint256 cap = x * OPERATOR_TOP_UP_BPS / 10_000;
        uint256 bound_ = maxTopUp < cap ? maxTopUp : cap;
        vm.prank(signer);
        (bool ok, bytes memory ret) =
            address(opHelper).call(abi.encodeCall(IFlashLiquidator.flashLiquidate, (_request(x, x, 0, maxTopUp, 0))));
        if (shortBy > bound_) {
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(IFlashLiquidatorErrors.TopUpExceeded.selector, shortBy, bound_));
            assertEq(usdcToken.balanceOf(safe), x);
        } else {
            assertTrue(ok);
            assertEq(abi.decode(ret, (uint256)), 0);
            assertEq(usdcToken.balanceOf(safe), x - shortBy, "top-up from the Safe");
        }
    }
}
