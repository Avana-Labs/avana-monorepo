// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {RouteMode} from "../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {SettlementReport} from "../../src/types/SettlementReport.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title LPVaultSwapWaterfallUnitTest
/// @notice The payout waterfall of a routed liquidation in the repaid debt asset (2.11 SPEC-LIQ-008 to SPEC-LIQ-010,
/// SPEC-LIQ-022, REQ-SWAP-026 to REQ-SWAP-028): Avana's fee from the oracle gain capped at the realized surplus, the
/// keeper reward, the borrower surplus above the oracle value, the caller's payout `keeperOut = Kf + R' − D − A − B`
/// paid by a plain transfer, the minimum payout and the exact conservation of the debt asset, on the real Aave V4 CDP
/// Spoke with the real Collateralization, PayoutEscrow and swap routes.
/// forge-config: default.isolate = false
contract LPVaultSwapWaterfallUnitTest is LPVaultSwapUnitBase {
    /// @notice 3.5 LIQ-069 shape: Bob's account at HF 0.933 (maximum bonus 10,500), `debtToCover = 1,950` USDC.
    /// Aave repays 1,950 USDC and seizes 975 vault tokens; the unwind returns 1,030.199625 USDC and 1,010.1 USDT; the
    /// USDT leg swaps at 0.9995; every payout equals the spec formulas evaluated independently, and the debt asset is
    /// conserved: `Kf + R + shortfall = D + A + B + keeperOut`.
    // TEST-051 verifies: SPEC-LIQ-004, SPEC-LIQ-006, SPEC-LIQ-008, SPEC-LIQ-009, SPEC-LIQ-010, SPEC-LIQ-022, REQ-SWAP-026, REQ-SWAP-028, REQ-SWAP-042, REQ-SWAP-094, INV-035, INV-036
    function test_TEST_051_routedExampleSettlesInDebtAsset() public {
        (address proxy,) = _bobAccount();
        uint256 debtBefore = _debtOf(proxy, usdcReserveId);
        Snap memory s0 = _snap(keeper);
        _fund(usdc, keeper, 1950e6);
        vm.recordLogs();
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate(_params(proxy, 1950e6));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(r.debtAsset, address(usdc), "debt asset");
        assertEq(r.debtRepaid, 1950e6, "D");
        assertEq(r.unitsSeized, 975e6, "c = D x 1.05 / 2.10");
        assertEq(r.callerFunds, 1950e6, "Kf");
        (uint256 a0, uint256 a1) = _released(975e6);
        assertEq(r.amountsOut[0], a0, "USDC released");
        assertEq(r.amountsOut[1], a1, "USDT released");
        Expect memory e = _expectUsdc(975e6, 1950e6, 1950e6, _routedRecovery(975e6), 10_500, P_VAULT, 0);
        _assertResult(r, e);
        assertEq(e.fee, 19_500_000, "A = 20 % of G = 97.5");
        assertEq(r.keeperOut, r.callerFunds + r.keeperReward, "keeperOut = Kf + kr");

        // Debt-asset conservation and who received what.
        assertEq(r.callerFunds + r.recovered + r.shortfall, r.debtRepaid + r.avanaFee + r.borrowerSurplus + r.keeperOut);
        assertEq(usdc.balanceOf(keeper), s0.callerUsdc + r.keeperOut, "caller paid keeperOut");
        assertEq(usdc.balanceOf(feeRecipient), s0.feeUsdc + r.avanaFee, "fee recipient paid A");
        assertEq(usdc.balanceOf(bob), 18_000e6, "borrower paid nothing beyond his loan");
        assertEq(_debtOf(proxy, usdcReserveId), debtBefore - 1950e6, "debt repaid on the Spoke");
        assertEq(vt.totalSupply(), s0.vtSupply - 975e6, "seized units burned");
        _assertNeutral(s0);
        _assertNoAllowances();

        (SettlementReport memory rep, bool found) = _settledReport(logs);
        assertTrue(found, "LiquidationSettled");
        assertEq(rep.debtReserveId, usdcReserveId, "report reserve");
        assertEq(rep.effectiveSlippageBps, 100, "s = min(100, 476)");
        assertEq(rep.bonusBps, 10_500, "bNet");
        assertEq(rep.surplus, e.surplus, "report S");
        assertEq(rep.minPayout, 0, "report minPayout");
        assertEq(uint8(rep.routeMode), uint8(RouteMode.PrimaryThenBackup), "report mode");
        assertEq(rep.routeUsed[0], 0, "USDC is the debt asset: no route");
        assertEq(rep.routeUsed[1], 1, "USDT over the primary");
        assertEq(_count(logs, BorrowerSurplusPaid.selector), 0, "no borrower surplus event");
    }

    /// @notice SPEC-LIQ-022: routes better than the oracle value leave `B = R_f − max(V, D)` for the borrower's
    /// wallet, paid after Avana's fee and before the caller, and `kr = G − A`.
    // TEST-051 verifies: SPEC-LIQ-022, REQ-SWAP-026, REQ-SWAP-027, Q-337
    function test_TEST_051_borrowerSurplusWhenRoutesBeatOracle() public {
        usdtUsdcPool.setRate(103, 100);
        (address proxy,) = _bobAccount();
        uint256 bobBefore = usdc.balanceOf(bob);
        _fund(usdc, keeper, 1950e6);
        uint256 recovered = 1_030_199_625 + uint256(1_010_100_000) * 103 / 100;
        vm.expectEmit(true, true, true, true, address(lvs));
        emit BorrowerSurplusPaid(proxy, bob, address(usdc), recovered - 2_047_500_000, false);
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate(_params(proxy, 1950e6));
        Expect memory e = _expectUsdc(975e6, 1950e6, 1950e6, recovered, 10_500, P_VAULT, 0);
        _assertResult(r, e);
        assertEq(r.borrowerSurplus, recovered - 2_047_500_000, "B = R - V");
        assertEq(r.keeperReward + r.avanaFee, 97_500_000, "kr + A = G");
        assertEq(usdc.balanceOf(bob), bobBefore + r.borrowerSurplus, "wallet paid B");
        assertEq(r.keeperOut, 1950e6 + r.keeperReward, "keeperOut = Kf + kr");
    }

    /// @notice SPEC-LIQ-009: a caller that routes its own swaps lower (a sandwich of its own legs, within the leg
    /// minimums) lowers `S` and `kr`, never `A`, while `S` covers the oracle-gain fee.
    // TEST-240 verifies: SPEC-LIQ-009, INV-036, INV-086, Q-256
    function test_TEST_240_selfSandwichKeepsFee() public {
        (address proxy,) = _bobAccount();
        LiquidationResult memory honest = _liquidateAs(keeper, _params(proxy, 1950e6));
        usdtUsdcPool.setRate(9950, 10_000); // 0.5 % below the oracle, above the leg minimum
        LiquidationResult memory sandwiched = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertLt(sandwiched.recovered, honest.recovered, "recovery lowered");
        assertEq(sandwiched.avanaFee, honest.avanaFee, "A unchanged");
        assertLt(sandwiched.keeperReward, honest.keeperReward, "the caller bears the loss");
        assertEq(sandwiched.avanaFee, 19_500_000, "A = 19.5 USDC");
    }

    /// @notice `A = min(⌊G × share / 1e4⌋, S)`: a dust liquidation (3 USDC) whose routes return 3.01 USDC leaves a
    /// surplus below 20 % of the 0.15 USDC gain, and the fee takes the whole surplus; the keeper reward is then 0.
    // TEST-240 verifies: SPEC-LIQ-009, SPEC-LIQ-022, INV-036, INV-086
    function test_TEST_240_feeAtMostSurplus() public {
        usdtUsdcPool.setRate(917, 1000);
        (, LiquidationResult memory r) = _bobLiquidation(keeper, 3e6);
        assertEq(r.debtRepaid, 3e6, "D = 3 USDC");
        assertEq(r.unitsSeized, 1_500_000, "c = 1.5 vault tokens");
        uint256 s = r.recovered - r.debtRepaid;
        assertLt(s, 30_000, "S below 20 % of G = 0.03 USDC");
        assertEq(r.avanaFee, s, "A = S");
        assertEq(r.keeperReward, 0, "kr = 0");
        assertEq(r.borrowerSurplus, 0, "B = 0");
        assertEq(r.keeperOut, r.callerFunds, "keeperOut = Kf");
        Expect memory e = _expectUsdc(r.unitsSeized, r.debtRepaid, r.callerFunds, r.recovered, 10_500, P_VAULT, 0);
        _assertResult(r, e);
    }

    /// @notice An oversized `debtToCover` (the Lens margin) changes neither `D`, `A` nor `kr` once Aave caps the
    /// repayment: Carol's whole debt of 1,950 USDC is repaid with `X = 1,950` and with `X = 2,047.5` alike, and the
    /// unused 97.5 USDC returns inside `keeperOut` (SPEC-LIQ-017), never swapped, never counted in `R`.
    // TEST-240 verifies: SPEC-LIQ-009, SPEC-LIQ-017, REQ-SWAP-089, REQ-SWAP-111, INV-086
    // TEST-051 verifies: SPEC-LIQ-010, SPEC-LIQ-017, REQ-SWAP-090
    function test_TEST_240_oversizedDebtToCoverCannotLowerFee() public {
        (address proxy,) = _carolAccount();
        uint256 debt = _debtOf(proxy, usdcReserveId);
        uint256 snapshot = vm.snapshotState();
        LiquidationResult memory exact = _liquidateAs(keeper, _params(proxy, debt));
        vm.revertToState(snapshot);
        Snap memory s0 = _snap(keeper);
        LiquidationResult memory big = _liquidateAs(keeper, _params(proxy, debt * 105 / 100));
        assertEq(big.debtRepaid, exact.debtRepaid, "Aave caps D");
        assertEq(big.unitsSeized, exact.unitsSeized, "same seizure");
        assertEq(big.recovered, exact.recovered, "leftover never counted in R");
        assertEq(big.avanaFee, exact.avanaFee, "A unchanged");
        assertEq(big.keeperReward, exact.keeperReward, "kr unchanged");
        assertEq(big.keeperOut - exact.keeperOut, big.callerFunds - exact.callerFunds, "leftover returned in full");
        Expect memory e =
            _expectUsdc(big.unitsSeized, big.debtRepaid, big.callerFunds, big.recovered, 10_500, 150_000_000, 0);
        _assertResult(big, e);
        _assertNeutral(s0);
    }

    /// @notice SPEC-LIQ-010: a recovery between the floor and `D` needs no top-up; the caller bears `D − R` in
    /// `keeperOut = Kf − (D − R)` and no fee, reward or surplus is paid. A 3 USDC dust liquidation whose USDT leg
    /// returns half its value stays above its floor (the unit and rounding allowance of SPEC-LIQ-005).
    // TEST-051 verifies: SPEC-LIQ-005, SPEC-LIQ-008, SPEC-LIQ-010, REQ-SWAP-029, INV-038, Q-397
    function test_TEST_051_recoveryBelowDebtCostsTheCaller() public {
        usdtUsdcPool.setRate(5, 10);
        (, LiquidationResult memory r) = _bobLiquidation(keeper, 3e6);
        assertLt(r.recovered, r.debtRepaid, "R < D");
        assertGe(r.recovered, r.minOut, "R >= minRec");
        assertEq(r.shortfall, 0, "no top-up");
        assertEq(r.avanaFee + r.keeperReward + r.borrowerSurplus, 0, "S = 0");
        assertEq(r.keeperOut, r.callerFunds - (r.debtRepaid - r.recovered), "keeperOut = Kf - (D - R)");
        Expect memory e = _expectUsdc(r.unitsSeized, r.debtRepaid, r.callerFunds, r.recovered, 10_500, P_VAULT, 0);
        _assertResult(r, e);
    }

    /// @notice REQ-SWAP-075: `PayoutTooLow(keeperOut, minPayout)` one unit above the payout; the exact payout passes.
    // TEST-176 verifies: REQ-SWAP-075, REQ-SWAP-079, Q-216, Q-345
    function test_TEST_176_payoutTooLowBoundary() public {
        (address proxy,) = _bobAccount();
        uint256 snapshot = vm.snapshotState();
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        vm.revertToState(snapshot);
        LiquidationParams memory p = _params(proxy, 1950e6);
        p.minPayout = r.keeperOut + 1;
        _expectLiquidateRevert(
            keeper, p, abi.encodeWithSelector(ILPVaultSwapErrors.PayoutTooLow.selector, r.keeperOut, r.keeperOut + 1)
        );
        p.minPayout = r.keeperOut;
        vm.prank(keeper);
        LiquidationResult memory again = lvs.liquidate(p);
        assertEq(again.keeperOut, r.keeperOut, "exact minimum passes");
    }

    /// @notice REQ-SWAP-028: a zero `feeRecipient` reverts every liquidation; the recipient is read on every call.
    // TEST-051 verifies: REQ-SWAP-028, REQ-SWAP-047
    function test_TEST_051_feeRecipientReadPerCall() public {
        (address proxy,) = _bobAccount();
        store.setFeeRecipient(address(0));
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _err(ILPVaultSwapErrors.InvalidFeeRecipient.selector));
        address treasury = makeAddr("newTreasury");
        store.setFeeRecipient(treasury);
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate(_params(proxy, 1950e6));
        assertEq(usdc.balanceOf(treasury), r.avanaFee, "the new recipient is paid");
        assertGt(r.avanaFee, 0, "fee paid");
    }

    /// @notice `avanaFeeShareBps` is read on every call: share 0 pays no fee and gives the gain to the caller; share
    /// 5,000 takes half the gain.
    // TEST-051 verifies: SPEC-LIQ-009, REQ-SWAP-047
    function test_TEST_051_feeShareReadPerCall() public {
        (address proxy,) = _bobAccount();
        store.setAvanaFeeShareBps(0);
        LiquidationResult memory zero = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertEq(zero.avanaFee, 0, "share 0");
        store.setAvanaFeeShareBps(5000);
        LiquidationResult memory half = _liquidateAs(keeper, _params(proxy, 1950e6));
        uint256 gain = _valueOf(half.unitsSeized, P_VAULT, PRICE_UNIT, 6) - half.debtRepaid;
        assertEq(half.avanaFee, gain / 2, "share 5,000");
        assertEq(zero.keeperReward, zero.recovered - zero.debtRepaid, "the whole surplus to the caller");
    }

    /// @notice The payout order of REQ-SWAP-026: Avana's fee, then the borrower surplus, then the caller (a payout
    /// token hook records the order of the three transfers).
    // TEST-051 verifies: REQ-SWAP-026, Q-097, Q-337
    function test_TEST_051_payoutOrderFeeBorrowerCaller() public {
        usdtUsdcPool.setRate(103, 100);
        (address proxy,) = _bobAccount();
        _fund(usdc, keeper, 1950e6);
        vm.recordLogs();
        vm.prank(keeper);
        lvs.liquidate(_params(proxy, 1950e6));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 transferSig = keccak256("Transfer(address,address,uint256)");
        uint256 feeAt;
        uint256 borrowerAt;
        uint256 callerAt;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(usdc) || logs[i].topics[0] != transferSig) continue;
            if (address(uint160(uint256(logs[i].topics[1]))) != address(lvs)) continue;
            address to = address(uint160(uint256(logs[i].topics[2])));
            if (to == feeRecipient) feeAt = i;
            if (to == bob) borrowerAt = i;
            if (to == keeper) callerAt = i;
        }
        assertGt(feeAt, 0, "fee paid");
        assertGt(borrowerAt, feeAt, "borrower after the fee");
        assertGt(callerAt, borrowerAt, "caller last");
    }
}
