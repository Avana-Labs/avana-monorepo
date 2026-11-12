// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title LPVaultSwapFundingUnitTest
/// @notice Caller funding of a liquidation (2.11 REQ-SWAP-011, REQ-SWAP-012, REQ-SWAP-016, REQ-SWAP-017, REQ-SWAP-088
/// to REQ-SWAP-090, REQ-SWAP-108): `debtToCover` pulled from `msg.sender` by `transferFrom` before any other transfer
/// and measured as `Kf` by balance delta (`FundingMismatch` unless `0 < Kf ≤ X`); Aave's bound is `Kf` with an exact
/// allowance reset to 0; `D` and `c` by delta; the leftover `Kf − D` returned in `keeperOut`; no flash source is read
/// or called; a donation before the call changes no amount.
/// forge-config: default.isolate = false
contract LPVaultSwapFundingUnitTest is LPVaultSwapUnitBase {
    address internal proxy;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
    }

    /// @notice The caller's `transferFrom` is the first debt-asset movement of the call; Aave's `liquidationCall` gets
    /// `Kf` as its bound and `receiveShares = false`; the Spoke's allowance is 0 afterwards.
    // TEST-048 verifies: REQ-SWAP-011, REQ-SWAP-016, REQ-SWAP-088, REQ-SWAP-090, Q-333, Q-404
    // TEST-197 verifies: REQ-SWAP-011, REQ-SWAP-016, REQ-SWAP-094
    function test_TEST_048_pullFirstThenAaveBoundIsKf() public {
        _fund(usdc, keeper, 1950e6);
        vm.expectCall(
            aave.cdpSpoke,
            abi.encodeCall(IAaveV4Spoke.liquidationCall, (vtReserveId, usdcReserveId, proxy, 1950e6, false))
        );
        vm.recordLogs();
        vm.prank(keeper);
        lvs.liquidate(_params(proxy, 1950e6));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 transferSig = keccak256("Transfer(address,address,uint256)");
        bool firstSeen;
        for (uint256 i = 0; i < logs.length && !firstSeen; ++i) {
            if (logs[i].emitter != address(usdc) || logs[i].topics[0] != transferSig) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), keeper, "first USDC move is from the caller");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(lvs), "to LPVaultSwap");
            firstSeen = true;
        }
        assertTrue(firstSeen, "caller pulled");
        assertEq(usdc.allowance(address(lvs), aave.cdpSpoke), 0, "Spoke allowance reset");
    }

    /// @notice A token that delivers more than it was asked (`Kf > X`) and one that delivers nothing are refused with
    /// `FundingMismatch` before anything else moves.
    // TEST-048 verifies: REQ-SWAP-011, REQ-SWAP-098, REQ-SWAP-108
    function test_TEST_048_fundingOutsideBoundsRefused() public {
        usdc.setBonus(1);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _err(ILPVaultSwapErrors.FundingMismatch.selector));
        usdc.setBonus(0);
        usdc.setDrain(1950e6);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _err(ILPVaultSwapErrors.FundingMismatch.selector));
        usdc.setDrain(0);
        _liquidateAs(keeper, _params(proxy, 1950e6));
    }

    /// @notice A token that returns `false` on the caller's `transferFrom` reverts the call (SafeERC20), and a caller
    /// without allowance or balance reverts in the token.
    // TEST-048 verifies: REQ-SWAP-011, REQ-SWAP-064
    function test_TEST_048_callerTransferFailureReverts() public {
        _fund(usdc, keeper, 1950e6);
        usdc.setReturnFalse(true);
        vm.prank(keeper);
        vm.expectRevert();
        lvs.liquidate(_params(proxy, 1950e6));
        usdc.setReturnFalse(false);
        vm.prank(carol);
        vm.expectRevert();
        lvs.liquidate(_params(proxy, 1950e6));
    }

    /// @notice SPEC-LIQ-017: Aave pulls `D ≤ Kf` and the leftover `Kf − D` returns inside `keeperOut`, never swapped:
    /// Carol's whole debt is repaid from a 5 % oversized funding.
    // TEST-048 verifies: REQ-SWAP-017, REQ-SWAP-089, REQ-SWAP-111, SPEC-LIQ-017, INV-070
    // TEST-055 verifies: REQ-SWAP-090
    // TEST-048 verifies: REQ-ROUTE-037
    function test_TEST_048_leftoverReturnedNotSwapped() public {
        (address carolProxy,) = _carolAccount();
        uint256 debt = _debtOf(carolProxy, usdcReserveId);
        uint256 x = debt * 105 / 100;
        uint256 usdtSwaps = usdtUsdcPool.swaps();
        LiquidationResult memory r = _liquidateAs(keeper, _params(carolProxy, x));
        assertEq(r.callerFunds, x, "Kf = X");
        assertLe(r.debtRepaid, r.callerFunds, "D <= Kf");
        assertEq(r.debtRepaid, debt, "whole debt repaid");
        assertEq(usdtUsdcPool.swaps(), usdtSwaps + 1, "only the USDT leg swapped");
        assertEq(r.keeperOut, r.callerFunds - r.debtRepaid + r.recovered - r.avanaFee - r.borrowerSurplus);
        assertGe(r.keeperOut, x - r.debtRepaid, "leftover inside keeperOut");
    }

    /// @notice REQ-SWAP-012: a liquidation never reads or calls the flash source or its lender, even with one set.
    // TEST-055 verifies: REQ-SWAP-012, REQ-SWAP-041, INV-040, INV-095, Q-404
    function test_TEST_055_noFlashLoanInLiquidate() public {
        uint256 loans = v3Pool.flashLoanCalls();
        vm.expectCall(address(flashSource), abi.encodeWithSignature("maxFlashLoan(address)", address(usdc)), 0);
        vm.expectCall(address(registry), abi.encodeWithSignature("flashSource()"), 0);
        _liquidateAs(keeper, _params(proxy, 1950e6));
        assertEq(v3Pool.flashLoanCalls(), loans, "no Pool loan");
    }

    /// @notice A donation of USDC, USDT and vault tokens to LPVaultSwap before the call changes no amount: every
    /// figure is a per-call delta, the donation stays where it is.
    // TEST-048 verifies: REQ-SWAP-019, REQ-SWAP-042, REQ-SWAP-108, SPEC-LIQ-006, Q-124
    function test_TEST_048_donationsChangeNothing() public {
        uint256 snapshot = vm.snapshotState();
        LiquidationResult memory clean = _liquidateAs(keeper, _params(proxy, 1950e6));
        vm.revertToState(snapshot);
        usdc.mint(address(lvs), 5e6);
        usdt.mint(address(lvs), 7e6);
        Snap memory s0 = _snap(keeper);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertEq(r.callerFunds, clean.callerFunds, "Kf");
        assertEq(r.debtRepaid, clean.debtRepaid, "D");
        assertEq(r.recovered, clean.recovered, "R");
        assertEq(r.keeperOut, clean.keeperOut, "keeperOut");
        _assertNeutral(s0);
        assertEq(usdc.balanceOf(address(lvs)), 5e6, "USDC donation kept, unspent");
        assertEq(usdt.balanceOf(address(lvs)), 7e6, "USDT donation kept, unspent");
    }

    /// @notice A transfer fee on the debt asset (REQ-SWAP-108): the measured `Kf` is below `X`, the Spoke is approved
    /// for exactly `Kf` and gets `Kf` as its bound, and the fee on the funding and on the payout falls on the caller
    /// alone (A unchanged).
    // TEST-048 verifies: REQ-SWAP-011, REQ-SWAP-016, REQ-SWAP-108, REQ-SWAP-123, Q-390
    function test_TEST_048_transferFeeMeasuredByDelta() public {
        uint256 snapshot = vm.snapshotState();
        LiquidationResult memory clean = _liquidateAs(keeper, _params(proxy, 1950e6));
        vm.revertToState(snapshot);
        // The fee only on the caller's funding transfer: a 10 bps fee switched on for the pull and off by the token's
        // hook right after it (Aave V4's Hub refuses a fee on the repayment itself, see the next test).
        _fund(usdc, keeper, 1950e6);
        usdc.setFeeBps(10);
        usdc.setHook(address(usdc), abi.encodeCall(PayoutToken.setFeeBps, (0)));
        uint256 kf = 1950e6 - 1950e6 * 10 / 10_000;
        vm.expectCall(
            aave.cdpSpoke, abi.encodeCall(IAaveV4Spoke.liquidationCall, (vtReserveId, usdcReserveId, proxy, kf, false))
        );
        vm.prank(keeper);
        (bool ok, bytes memory ret) = address(lvs).call(abi.encodeCall(lvs.liquidate, (_params(proxy, 1950e6))));
        assertTrue(ok, "settles by measured amounts");
        LiquidationResult memory r = abi.decode(ret, (LiquidationResult));
        assertEq(r.callerFunds, kf, "Kf measured");
        assertLe(r.debtRepaid, kf, "D <= Kf");
        assertLe(r.avanaFee, clean.avanaFee, "A never raised by the fee");
        assertEq(usdc.allowance(address(lvs), aave.cdpSpoke), 0, "exact approval reset");
    }

    /// @notice A transfer fee that stays on for the repayment is refused by Aave V4's Hub inside `liquidationCall`
    /// (`InsufficientTransferred`); the Aave error passes through unchanged and nothing settles.
    // TEST-048 verifies: REQ-SWAP-055, REQ-SWAP-123
    function test_TEST_048_aaveRefusesFeeOnRepayment() public {
        _fund(usdc, keeper, 1950e6);
        usdc.setFeeBps(10);
        uint256 debt = _debtOf(proxy, usdcReserveId);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSignature("InsufficientTransferred(uint256)", uint256(1_948_050)));
        lvs.liquidate(_params(proxy, 1950e6));
        assertEq(_debtOf(proxy, usdcReserveId), debt, "nothing settled");
    }
}
