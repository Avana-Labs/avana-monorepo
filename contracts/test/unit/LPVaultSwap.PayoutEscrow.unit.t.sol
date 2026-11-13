// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {LVSGasSink, LVSShortChange} from "../utils/mocks/LPVaultSwapMocks.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";

/// @title LPVaultSwapPayoutEscrowUnitTest
/// @notice Payout delivery (2.11 REQ-SWAP-076, REQ-SWAP-082, REQ-SWAP-083): Avana's fee, the borrower surplus and every
/// residue are sent by a gas-limited transfer of exactly `PAYOUT_TRANSFER_GAS` after a gas check of 111,588; what does
/// not leave LPVaultSwap (a blocklisted or reverting recipient, a gas-burning token, a token that returns `true` but
/// moves less) is deposited in the PayoutEscrow credited to the recipient and the liquidation completes; the caller's
/// `keeperOut` is never escrowed and its failed transfer reverts the call.
/// forge-config: default.isolate = false
contract LPVaultSwapPayoutEscrowUnitTest is LPVaultSwapUnitBase {
    address internal proxy;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
    }

    /// @notice Circle blocklists the treasury Safe that is `feeRecipient`: the fee transfer reverts inside its 100,000
    /// gas, LPVaultSwap deposits `A` in the escrow credited to it, pays the caller and completes; the Safe claims later.
    // TEST-179 verifies: REQ-SWAP-028, REQ-SWAP-076, REQ-SWAP-082, INV-061, Q-214, Q-389
    // TEST-286 verifies: REQ-SWAP-076, REQ-SWAP-082
    function test_TEST_179_feeRecipientBlocklistedEscrowed() public {
        usdc.setBlocked(feeRecipient, true);
        Snap memory s0 = _snap(keeper);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertEq(r.avanaFee, 19_500_000, "A computed as usual");
        assertEq(escrow.claimable(address(usdc), feeRecipient), r.avanaFee, "A credited to feeRecipient");
        assertEq(usdc.balanceOf(address(escrow)), s0.escrowUsdc + r.avanaFee, "escrow holds A");
        assertEq(usdc.balanceOf(keeper), s0.callerUsdc + 1950e6 - 1950e6 + r.keeperOut, "caller paid in full");
        _assertNeutral(s0);
        _assertNoAllowances();
        usdc.setBlocked(feeRecipient, false);
        address newTreasury = makeAddr("newTreasury");
        vm.prank(feeRecipient);
        escrow.claim(address(usdc), newTreasury);
        assertEq(usdc.balanceOf(newTreasury), r.avanaFee, "claimed to a new address");
    }

    /// @notice A borrower whose wallet the debt asset blocks: `B` is escrowed for the wallet and
    /// `BorrowerSurplusPaid(..., escrowed = true)` is emitted.
    // TEST-179 verifies: REQ-SWAP-026, REQ-SWAP-027, REQ-SWAP-076, REQ-SWAP-082, Q-337
    function test_TEST_179_blocklistedBorrowerEscrowed() public {
        usdtUsdcPool.setRate(103, 100);
        usdc.setBlocked(bob, true);
        uint256 recovered = 1_030_199_625 + uint256(1_010_100_000) * 103 / 100;
        uint256 b = recovered - 2_047_500_000;
        _fund(usdc, keeper, 1950e6);
        vm.expectEmit(true, true, true, true, address(lvs));
        emit BorrowerSurplusPaid(proxy, bob, address(usdc), b, true);
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate(_params(proxy, 1950e6));
        assertEq(r.borrowerSurplus, b, "B");
        assertEq(escrow.claimable(address(usdc), bob), b, "B credited to the wallet");
    }

    /// @notice A token whose transfer burns all the gas it is given (a gas-burning hook) cannot revert the
    /// liquidation: the fee transfer runs out of its 100,000 gas and `A` is escrowed.
    // TEST-179 verifies: REQ-SWAP-076, REQ-SWAP-082, Q-214
    function test_TEST_179_gasBurnerEscrowed() public {
        LVSGasSink sink = new LVSGasSink();
        _fund(usdc, keeper, 1950e6);
        usdc.setHook(address(sink), "");
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate{gas: 10_000_000}(_params(proxy, 1950e6));
        assertEq(escrow.claimable(address(usdc), feeRecipient), r.avanaFee, "A escrowed after an out-of-gas transfer");
        assertGt(r.avanaFee, 0, "fee due");
    }

    /// @notice A transfer that returns `true` but moves less than asked out of LPVaultSwap is measured: exactly the
    /// part that did not leave is escrowed for the recipient, and LPVaultSwap's balance is unchanged over the call.
    // TEST-179 verifies: REQ-SWAP-076, REQ-SWAP-082, REQ-SWAP-108, INV-061
    function test_TEST_179_underDeliveryEscrowedForTheRest() public {
        uint256 kept = 4_000_000;
        LVSShortChange shortChange = new LVSShortChange(address(usdc), address(lvs), kept);
        _fund(usdc, keeper, 1950e6);
        Snap memory s0 = _snap(keeper);
        usdc.setHook(address(shortChange), "");
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate{gas: 10_000_000}(_params(proxy, 1950e6));
        assertEq(usdc.balanceOf(feeRecipient), s0.feeUsdc + r.avanaFee, "the recipient got the whole transfer");
        assertEq(escrow.claimable(address(usdc), feeRecipient), kept, "the part that stayed is escrowed");
        _assertNeutral(s0);
    }

    /// @notice The caller's payout is never escrowed: a caller the debt asset blocks makes the whole liquidation revert.
    // TEST-179 verifies: REQ-SWAP-026, REQ-SWAP-064, REQ-SWAP-082
    // TEST-286 verifies: REQ-SWAP-026, REQ-SWAP-064
    function test_TEST_179_keeperOutNeverEscrowed() public {
        _fund(usdc, keeper, 1950e6);
        uint256 debt = _debtOf(proxy, usdcReserveId);
        // The caller's own funding pull is unaffected; only its incoming payout is blocked.
        usdc.setHook(address(usdc), abi.encodeCall(PayoutToken.setBlocked, (keeper, true)));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(PayoutToken.Blocked.selector, keeper));
        lvs.liquidate(_params(proxy, 1950e6));
        assertEq(_debtOf(proxy, usdcReserveId), debt, "nothing settled");
        assertEq(escrow.claimable(address(usdc), keeper), 0, "never escrowed");
    }

    /// @notice REQ-SWAP-076: the payout transfer always gets its full 100,000 gas. Across a sweep of call gas limits
    /// no run settles with the fee escrowed: either it reverts (`InsufficientGas` among them) or the fee is delivered.
    // TEST-179 verifies: REQ-SWAP-076, REQ-SWAP-083, REQ-SWAP-114, Q-214
    function test_TEST_179_insufficientGasNeverForcesEscrow() public {
        _fund(usdc, keeper, 100 * 1950e6);
        uint256 snapshot = vm.snapshotState();
        uint256 g0 = gasleft();
        vm.prank(keeper);
        lvs.liquidate(_params(proxy, 1950e6));
        uint256 used = g0 - gasleft();
        vm.revertToState(snapshot);
        bool sawInsufficientGas = false;
        for (uint256 cut = 10_000; cut <= 200_000; cut += 5000) {
            snapshot = vm.snapshotState();
            vm.prank(keeper);
            try lvs.liquidate{gas: used - cut}(_params(proxy, 1950e6)) returns (LiquidationResult memory) {
                assertEq(escrow.claimable(address(usdc), feeRecipient), 0, "fee escrowed for lack of gas");
            } catch (bytes memory reason) {
                if (bytes4(reason) == ILPVaultSwapErrors.InsufficientGas.selector) sawInsufficientGas = true;
            }
            vm.revertToState(snapshot);
        }
        assertTrue(sawInsufficientGas, "the gas check fired in the sweep");
    }

    /// @notice A token that blocks the escrow itself makes a failed payout revert the whole liquidation (the issuer
    /// playbook), and a payout that succeeds never touches the escrow.
    // TEST-179 verifies: REQ-SWAP-064, REQ-SWAP-076
    function test_TEST_179_escrowBlockedReverts() public {
        usdc.setBlocked(feeRecipient, true);
        usdc.setBlocked(address(escrow), true);
        _expectLiquidateRevert(
            keeper, _params(proxy, 1950e6), abi.encodeWithSelector(PayoutToken.Blocked.selector, address(escrow))
        );
        usdc.setBlocked(feeRecipient, false);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertEq(usdc.balanceOf(feeRecipient), r.avanaFee, "delivered directly");
    }

    /// @notice A zero fee (share 0) is skipped: no transfer is attempted, so a token that reverts on zero amounts
    /// settles.
    // TEST-179 verifies: REQ-SWAP-077
    function test_TEST_179_zeroPayoutSkipped() public {
        store.setAvanaFeeShareBps(0);
        usdc.setRevertOnZero(true);
        usdt.setRevertOnZero(true);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertEq(r.avanaFee, 0, "no fee");
        assertEq(r.borrowerSurplus, 0, "no surplus");
    }
}
