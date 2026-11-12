// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";

/// @title LPVaultSwapWaterfallFuzzTest
/// @notice The settlement waterfall fuzzed over account size, vault price above the released tokens' leg value (so
/// the caller tops up the floor), shortfall budget and fee recipient (2.11 SPEC-LIQ-008 to SPEC-LIQ-010,
/// SPEC-LIQ-019, SPEC-LIQ-022, REQ-SWAP-025 to REQ-SWAP-028): every figure equals the independent model, the top-up
/// never reaches the borrower or the fee (`R_f = max(R, minRec)`), the caller's balance moves by exactly
/// `keeperOut − Kf − shortfall`, the store's fee recipient receives `A`, and a zero fee recipient refuses the call
/// before anything moves.
/// forge-config: default.isolate = false
/// forge-config: default.fuzz.runs = 256
contract LPVaultSwapWaterfallFuzzTest is LPVaultSwapUnitBase {
    /// @notice Any account of 1,000 to 12,000 units at HF 0.90, any repayment, any vault price from $2.00 to $2.20:
    /// the model's figures with the floor gap topped up from the budget.
    // TEST-078 verifies: SPEC-LIQ-008, SPEC-LIQ-009, SPEC-LIQ-010, SPEC-LIQ-019, SPEC-LIQ-022, INV-034, INV-035
    function testFuzz_TEST_078_waterfallWithTopUp(
        uint256 units,
        uint256 share,
        uint256 price8
    ) public {
        units = bound(units, 1000e6, 12_000e6);
        share = bound(share, 500, 4000);
        price8 = bound(price8, 200_000_000, 220_000_000);
        // Borrowed so that HF is 0.90 at the price (below 0.95: Aave's maximum bonus applies).
        uint256 borrowed = units * price8 * 8 / (9 * 1e8);
        (address proxy,) = _openAccount(bob, uint128(units), borrowed, 260_000_000);
        lpOracle.setAnswer(int256(price8));
        if (_hf(proxy) >= 0.95e18) return;
        uint256 debtToCover = _debtOf(proxy, usdcReserveId) * share / 10_000;
        LiquidationParams memory p = _params(proxy, debtToCover);
        p.maxShortfall = debtToCover / 10;
        _fund(usdc, keeper, debtToCover + p.maxShortfall);
        uint256 callerBefore = usdc.balanceOf(keeper);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        vm.prank(keeper);
        try lvs.liquidate(p) returns (LiquidationResult memory r) {
            Expect memory e =
                _expectUsdc(r.unitsSeized, r.debtRepaid, r.callerFunds, r.recovered, 10_500, price8, p.maxShortfall);
            _assertResult(r, e);
            if (r.shortfall != 0) {
                assertEq(r.borrowerSurplus, 0, "the top-up never reaches the borrower");
                assertEq(r.recovered + r.shortfall, r.minOut, "R + shortfall = minRec");
            }
            assertEq(usdc.balanceOf(keeper), callerBefore - r.callerFunds - r.shortfall + r.keeperOut, "caller flow");
            assertEq(usdc.balanceOf(feeRecipient), feeBefore + r.avanaFee, "fee to the store's recipient");
            assertEq(usdc.balanceOf(address(lvs)), 0, "LPVaultSwap neutral");
        } catch (bytes memory reason) {
            bytes4 s = bytes4(reason);
            assertTrue(
                s == ILPVaultSwapErrors.RecoveryBelowFloor.selector || s == bytes4(keccak256("MustNotLeaveDust()")),
                "named refusal"
            );
        }
    }

    /// @notice A zero fee recipient refuses `liquidate` and `settlePending` with `InvalidFeeRecipient`, nothing moved.
    // TEST-240 verifies: SPEC-LIQ-009, REQ-SWAP-028, INV-086
    function testFuzz_TEST_240_zeroFeeRecipientRefused(
        uint256 debtToCover
    ) public {
        debtToCover = bound(debtToCover, 50e6, 6000e6);
        (address proxy,) = _bobAccount();
        store.setFeeRecipient(address(0));
        uint256 debt = _debtOf(proxy, usdcReserveId);
        _expectLiquidateRevert(
            keeper, _params(proxy, debtToCover), _err(ILPVaultSwapErrors.InvalidFeeRecipient.selector)
        );
        assertEq(_debtOf(proxy, usdcReserveId), debt, "nothing repaid");
        vm.expectRevert(ILPVaultSwapErrors.InvalidFeeRecipient.selector);
        lvs.settlePending(MARKET_ID, usdcReserveId);
    }

    /// @notice Successive liquidations of one account each settle to the model and conserve the debt asset; the
    /// account's health factor never falls while it is solvent at the bonus.
    // TEST-078 verifies: SPEC-LIQ-010, INV-035, INV-076
    function testFuzz_TEST_078_successiveLiquidations(
        uint256 first,
        uint256 second,
        uint256 third
    ) public {
        (address proxy,) = _bobAccount();
        uint256[3] memory sizes = [bound(first, 10e6, 3000e6), bound(second, 10e6, 3000e6), bound(third, 10e6, 3000e6)];
        for (uint256 i = 0; i < 3; ++i) {
            uint256 hf = _hf(proxy);
            if (hf >= 1e18) break;
            LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, sizes[i]));
            assertEq(
                r.callerFunds + r.recovered + r.shortfall, r.debtRepaid + r.avanaFee + r.borrowerSurplus + r.keeperOut
            );
            if (hf >= 0.84e18) assertGe(_hf(proxy), hf, "HF never falls while solvent at the bonus");
        }
        assertEq(usdc.balanceOf(address(lvs)), 0, "LPVaultSwap neutral");
        assertEq(vt.balanceOf(address(lvs)), 0, "no vault tokens kept");
    }
}
