// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";
import {LVSShortChange} from "../utils/mocks/LPVaultSwapMocks.sol";

/// @title LPVaultSwapDeliveryFuzzTest
/// @notice Gas-limited payout delivery fuzzed (2.11 REQ-SWAP-076, REQ-SWAP-082, INV-061): for any fee share, route
/// rate (so any borrower surplus), blocked or open fee recipient and wallet, and any part of a transfer that stays
/// with LPVaultSwap, every payout due reaches its recipient or the escrow credited to it, the sum of what arrived and
/// what was escrowed equals the amount due, the caller is paid `keeperOut` directly, and LPVaultSwap ends with no
/// balance change and no allowance.
/// forge-config: default.isolate = false
/// forge-config: default.fuzz.runs = 256
contract LPVaultSwapDeliveryFuzzTest is LPVaultSwapUnitBase {
    address internal proxy;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
    }

    /// @notice Blocked or open recipients at any fee share and route rate: arrived + escrowed = due for `A` and `B`.
    // TEST-179 verifies: REQ-SWAP-026, REQ-SWAP-027, REQ-SWAP-076, REQ-SWAP-082, INV-061, Q-214, Q-389
    function testFuzz_TEST_179_everyPayoutArrivesOrIsEscrowed(
        uint16 share,
        uint256 rateBps,
        bool feeBlocked,
        bool walletBlocked
    ) public {
        share = uint16(bound(share, 0, 5000));
        rateBps = bound(rateBps, 9950, 10_400);
        store.setAvanaFeeShareBps(share);
        usdtUsdcPool.setRate(rateBps, 10_000);
        usdtUsdcPool2.setRate(rateBps, 10_000);
        usdc.setBlocked(feeRecipient, feeBlocked);
        usdc.setBlocked(bob, walletBlocked);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 walletBefore = usdc.balanceOf(bob);
        Snap memory s0 = _snap(keeper);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        uint256 feeArrived = usdc.balanceOf(feeRecipient) - feeBefore;
        uint256 walletArrived = usdc.balanceOf(bob) - walletBefore;
        uint256 feeEscrowed = escrow.claimable(address(usdc), feeRecipient);
        uint256 walletEscrowed = escrow.claimable(address(usdc), bob);
        assertEq(feeArrived + feeEscrowed, r.avanaFee, "A arrived or escrowed");
        assertEq(walletArrived + walletEscrowed, r.borrowerSurplus, "B arrived or escrowed");
        assertEq(feeEscrowed, feeBlocked ? r.avanaFee : 0, "A escrowed exactly when the recipient is blocked");
        assertEq(walletEscrowed, walletBlocked ? r.borrowerSurplus : 0, "B escrowed exactly when the wallet is blocked");
        assertEq(usdc.balanceOf(keeper), s0.callerUsdc + 1950e6 - r.callerFunds + r.keeperOut, "caller paid directly");
        assertEq(
            usdc.balanceOf(address(escrow)),
            s0.escrowUsdc + feeEscrowed + walletEscrowed,
            "escrow holds what it credits"
        );
        _assertNeutral(s0);
        _assertNoAllowances();
    }

    /// @notice A transfer that returns `true` but leaves any part `k` of the fee with LPVaultSwap: exactly `k` is
    /// escrowed for the recipient, the rest arrives, LPVaultSwap's balance is unchanged.
    // TEST-179 verifies: REQ-SWAP-076, REQ-SWAP-082, REQ-SWAP-108, INV-061
    function testFuzz_TEST_179_anyUnderDeliveryEscrowed(
        uint256 kept
    ) public {
        uint256 probe;
        {
            uint256 snapshot = vm.snapshotState();
            probe = _liquidateAs(keeper, _params(proxy, 1950e6)).avanaFee;
            vm.revertToState(snapshot);
        }
        kept = bound(kept, 1, probe);
        LVSShortChange shortChange = new LVSShortChange(address(usdc), address(lvs), kept);
        _fund(usdc, keeper, 1950e6);
        Snap memory s0 = _snap(keeper);
        usdc.setHook(address(shortChange), "");
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate{gas: 10_000_000}(_params(proxy, 1950e6));
        assertEq(r.avanaFee, probe, "same fee");
        assertEq(escrow.claimable(address(usdc), feeRecipient), kept, "the part that stayed is escrowed");
        _assertNeutral(s0);
    }

    /// @notice After an escrow, the recipient claims its whole credit to any address it names, once.
    // TEST-179 verifies: REQ-SWAP-082, REQ-ESCROW-001
    function testFuzz_TEST_179_escrowedFeeClaimable(
        address to
    ) public {
        vm.assume(to != address(0) && to.code.length == 0 && uint160(to) > 0xffff && to != feeRecipient);
        vm.assume(to != address(escrow) && to != address(lvs));
        usdc.setBlocked(feeRecipient, true);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        usdc.setBlocked(feeRecipient, false);
        uint256 before = usdc.balanceOf(to);
        vm.prank(feeRecipient);
        escrow.claim(address(usdc), to);
        assertEq(usdc.balanceOf(to), before + r.avanaFee, "whole credit claimed");
        assertEq(escrow.claimable(address(usdc), feeRecipient), 0, "credit cleared");
        vm.prank(feeRecipient);
        vm.expectRevert();
        escrow.claim(address(usdc), to);
    }
}
