// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";

/// @title LPVaultSwapUsdcDebtUnitTest
/// @notice A liquidation of the 6-decimal USDC reserve (5.1 TEST-197) on the real local Aave V4 with the market's real
/// swap routes: the caller's USDC funds `Kf`, Aave is called with exactly `Kf`, the USDT leg is swapped into USDC over
/// the primary route with its oracle minimum, no flash source is called and no GHO moves, and LPVaultSwap pays out
/// every USDC it received.
/// forge-config: default.isolate = false
contract LPVaultSwapUsdcDebtUnitTest is LPVaultSwapUnitBase {
    /// @notice Bob's account, `debtToCover = 1,950` USDC: `liquidationCall(vtReserve, usdcReserve, proxy, 1,950e6,
    /// false)`; the unwind returns USDC and USDT; only the USDT leg is routed, as `swap(a₁, minOut₁)` into USDC; GHO's
    /// supply and every GHO balance are unchanged; `Kf + R = D + A + B + keeperOut` and LPVaultSwap ends neutral with
    /// no allowance.
    // TEST-197 verifies: REQ-SWAP-011, REQ-SWAP-016, REQ-SWAP-022, REQ-SWAP-042, REQ-SWAP-088, REQ-SWAP-094
    function test_TEST_197_usdcDebtSettlesOverItsRoutes() public {
        (address proxy,) = _bobAccount();
        (uint256 a0, uint256 a1) = _released(975e6);
        uint256 minOut = _usdtLegMinOut(a1, 100, 1);
        uint256 ghoSupply = gho.totalSupply();
        Snap memory s0 = _snap(keeper);
        _fund(usdc, keeper, 1950e6);
        vm.expectCall(
            aave.cdpSpoke,
            abi.encodeCall(IAaveV4Spoke.liquidationCall, (vtReserveId, usdcReserveId, proxy, 1950e6, false)),
            1
        );
        vm.expectCall(address(usdtPrimary), abi.encodeCall(ISettlementRoute.swap, (a1, minOut)), 1);
        vm.expectCall(address(usdcToGho), abi.encodeWithSelector(ISettlementRoute.swap.selector), 0);
        vm.expectCall(address(usdtToGho), abi.encodeWithSelector(ISettlementRoute.swap.selector), 0);
        vm.expectCall(address(flashSource), abi.encodeWithSignature("flashLoan(address,uint256,address,bytes)"), 0);
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate(_params(proxy, 1950e6));

        assertEq(r.debtAsset, address(usdc), "paid in USDC");
        assertEq(r.callerFunds, 1950e6, "Kf");
        assertEq(r.debtRepaid, 1950e6, "D");
        assertEq(r.amountsOut[0], a0, "USDC released, not swapped");
        assertEq(r.amountsOut[1], a1, "USDT released");
        assertEq(r.recovered, _routedRecovery(975e6), "R = the USDC leg plus the USDT leg routed into USDC");
        assertGe(r.recovered - a0, minOut, "the USDT leg met its minimum");
        assertEq(
            r.callerFunds + r.recovered + r.shortfall,
            r.debtRepaid + r.avanaFee + r.borrowerSurplus + r.keeperOut,
            "Kf + R = D + A + B + keeperOut"
        );
        assertEq(usdc.balanceOf(keeper), s0.callerUsdc + r.keeperOut, "the caller is paid keeperOut in USDC");
        assertEq(usdc.balanceOf(feeRecipient), s0.feeUsdc + r.avanaFee, "fee in USDC");
        assertEq(gho.totalSupply(), ghoSupply, "no GHO minted or burned");
        assertEq(gho.balanceOf(keeper), s0.callerGho, "no GHO to the caller");
        assertEq(gho.balanceOf(feeRecipient), s0.feeGho, "no GHO to the fee recipient");
        _assertNeutral(s0);
        _assertNoAllowances();
    }

    /// @notice Carol's small account owes 1,950 USDC: a caller funding 2,000 USDC has `Kf = 2,000`, Aave pulls only
    /// what the whole debt needs, and the unused `Kf − D` returns inside `keeperOut` in the same call.
    // TEST-197 verifies: REQ-SWAP-011, REQ-SWAP-016, REQ-SWAP-094
    function test_TEST_197_unusedFundingReturnsInKeeperOut() public {
        (address proxy,) = _carolAccount();
        Snap memory s0 = _snap(keeper);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 2000e6));
        assertEq(r.callerFunds, 2000e6, "Kf");
        assertLt(r.debtRepaid, r.callerFunds, "Aave pulled less than Kf");
        assertEq(_debtOf(proxy, usdcReserveId), 0, "the whole debt repaid");
        assertEq(
            r.callerFunds + r.recovered + r.shortfall,
            r.debtRepaid + r.avanaFee + r.borrowerSurplus + r.keeperOut,
            "Kf - D is inside keeperOut"
        );
        assertEq(usdc.balanceOf(keeper), s0.callerUsdc + r.keeperOut, "paid");
        _assertNeutral(s0);
    }

    /// @notice A recovery below the floor with no caller top-up reverts `RecoveryBelowFloor`: the vault is priced at
    /// $2.15 while its released tokens fetch about $2.09 a unit, every leg meets its minimum, and nothing moves.
    // TEST-197 verifies: REQ-SWAP-025, SPEC-LIQ-005
    function test_TEST_197_recoveryBelowFloorWithoutTopUpReverts() public {
        (address proxy,) = _bobAccount();
        lpOracle.setAnswer(215_000_000);
        uint256 debt = _debtOf(proxy, usdcReserveId);
        _expectLiquidateRevert(
            keeper, _params(proxy, 1950e6), abi.encodeWithSelector(ILPVaultSwapErrors.RecoveryBelowFloor.selector)
        );
        assertEq(_debtOf(proxy, usdcReserveId), debt, "nothing repaid");
    }
}
