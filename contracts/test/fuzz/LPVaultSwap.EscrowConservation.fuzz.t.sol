// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {IPayoutEscrow} from "../../src/liquidation/payout-escrow/IPayoutEscrow.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";

/// @title LPVaultSwapEscrowConservationFuzzTest
/// @notice Escrow conservation driven by the real LPVaultSwap on the local Aave V4 (5.1 TEST-173): routed liquidations
/// whose Avana-fee and borrower-surplus transfers fail for a fuzzed choice of blocklisted recipients, claims by the
/// credited accounts to chosen recipients, claims attempted by other addresses and donations to the escrow. After every
/// step, for each credited account the amount credited by deposits equals the amount claimed plus its `claimable`,
/// `totalClaimable` is the sum of the credits, the escrow's balance is the credits plus the donations, only LPVaultSwap
/// deposits, and the caller's `keeperOut` is never deposited.
/// forge-config: default.isolate = false
/// forge-config: default.fuzz.runs = 64
contract LPVaultSwapEscrowConservationFuzzTest is LPVaultSwapUnitBase {
    address internal proxy;
    address internal newTreasury = makeAddr("newTreasury");
    address internal bobWallet = makeAddr("bobNewWallet");
    address internal stranger = makeAddr("stranger");

    uint256 internal creditedFee;
    uint256 internal creditedBob;
    uint256 internal claimedFee;
    uint256 internal claimedBob;
    uint256 internal donated;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
        // Routes paying above the oracle value leave a borrower surplus in every liquidation.
        usdtUsdcPool.setRate(103, 100);
        usdtUsdcPool2.setRate(103, 100);
        // Anything the escrow holds before the first liquidation is unattributed, like a donation.
        donated = usdc.balanceOf(address(escrow));
    }

    // TEST-173 verifies: REQ-SWAP-076, REQ-SWAP-082, INV-061, Q-214
    function testFuzz_TEST_173_escrowConservedThroughLiquidationsAndClaims(
        uint256 seed
    ) public {
        for (uint256 round = 0; round < 4; ++round) {
            uint256 bits = seed >> (round * 8);
            bool blockFee = bits & 1 != 0;
            bool blockBob = bits & 2 != 0;
            usdc.setBlocked(feeRecipient, blockFee);
            usdc.setBlocked(bob, blockBob);

            uint256 feeBefore = escrow.claimable(address(usdc), feeRecipient);
            uint256 bobBefore = escrow.claimable(address(usdc), bob);
            uint256 keeperBefore = usdc.balanceOf(keeper);
            LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 400e6));
            assertGt(r.avanaFee, 0, "a fee to pay");
            assertGt(r.borrowerSurplus, 0, "a surplus to pay");
            uint256 feeDeposit = escrow.claimable(address(usdc), feeRecipient) - feeBefore;
            uint256 bobDeposit = escrow.claimable(address(usdc), bob) - bobBefore;
            assertEq(feeDeposit, blockFee ? r.avanaFee : 0, "the fee is escrowed only when its transfer fails");
            assertEq(bobDeposit, blockBob ? r.borrowerSurplus : 0, "B is escrowed only when its transfer fails");
            creditedFee += feeDeposit;
            creditedBob += bobDeposit;
            assertEq(usdc.balanceOf(keeper), keeperBefore + r.keeperOut, "keeperOut paid to the caller");
            assertEq(escrow.claimable(address(usdc), keeper), 0, "keeperOut is never deposited");
            _assertConserved();

            usdc.setBlocked(feeRecipient, false);
            usdc.setBlocked(bob, false);
            if (bits & 4 != 0 && escrow.claimable(address(usdc), feeRecipient) != 0) {
                uint256 got = usdc.balanceOf(newTreasury);
                vm.prank(feeRecipient);
                uint256 amount = escrow.claim(address(usdc), newTreasury);
                assertEq(usdc.balanceOf(newTreasury), got + amount, "paid to the recipient the account named");
                claimedFee += amount;
            }
            if (bits & 8 != 0 && escrow.claimable(address(usdc), bob) != 0) {
                uint256 got = usdc.balanceOf(bobWallet);
                vm.prank(bob);
                uint256 amount = escrow.claim(address(usdc), bobWallet);
                assertEq(usdc.balanceOf(bobWallet), got + amount, "paid to the recipient the account named");
                claimedBob += amount;
            }
            vm.prank(stranger);
            vm.expectRevert(IPayoutEscrow.NothingToClaim.selector);
            escrow.claim(address(usdc), stranger);
            if (bits & 16 != 0) {
                usdc.mint(address(escrow), 7);
                donated += 7;
            }
            _assertConserved();
        }

        usdc.mint(stranger, 1e6);
        vm.startPrank(stranger);
        usdc.approve(address(escrow), 1e6);
        vm.expectRevert(IPayoutEscrow.NotLPVaultSwap.selector);
        escrow.deposit(address(usdc), stranger, 1e6);
        vm.stopPrank();
        _assertConserved();
    }

    function _assertConserved() internal view {
        uint256 fee = escrow.claimable(address(usdc), feeRecipient);
        uint256 b = escrow.claimable(address(usdc), bob);
        assertEq(creditedFee, claimedFee + fee, "fee recipient: credited = claimed + claimable");
        assertEq(creditedBob, claimedBob + b, "borrower: credited = claimed + claimable");
        assertEq(escrow.totalClaimable(address(usdc)), fee + b, "totalClaimable is the sum of the credits");
        assertEq(usdc.balanceOf(address(escrow)), fee + b + donated, "balance = credits + donations");
    }
}
