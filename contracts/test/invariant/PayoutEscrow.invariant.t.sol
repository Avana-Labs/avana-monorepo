// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PayoutEscrow} from "../../src/liquidation/payout-escrow/PayoutEscrow.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {PayoutDepositor} from "../utils/mocks/PayoutEscrowActors.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {EscrowHandler} from "./handlers/EscrowHandler.sol";

/// @title PayoutEscrowInvariantTest
/// @notice Escrow side of TEST-173: random sequences of failed-payout deposits by LPVaultSwap under the Lock (one
/// token with an issuer fee switched on and off), claims by credited accounts to chosen and blocklisted recipients,
/// claims by addresses without a credit, deposits by outsiders and by LPVaultSwap without the Lock, and dust
/// donations. After every call, for every token and account: credited = claimed + held; `totalClaimable` is the sum
/// of the credits; the escrow's balance is `totalClaimable` plus the donations; no claim paid other than the whole
/// credit to the named recipient; nothing but LPVaultSwap under the Lock deposited.
/// @dev The liquidation side (LPVaultSwap's routed payouts failing for reverting and blocklisted recipients) joins this
/// row when LPVaultSwap lands; the handler's `deposit` stands in for it.
contract PayoutEscrowInvariantTest is AvanaTest {
    EscrowHandler internal handler;
    PayoutEscrow internal escrow;
    PayoutToken[2] internal tokens;
    address[3] internal accounts;

    function setUp() public {
        PayoutDepositor swap = new PayoutDepositor();
        address adapter = makeAddr("aaveAdapter");
        Lock lock = new Lock(adapter, address(swap));
        escrow = new PayoutEscrow(address(swap), address(lock));
        swap.setUp(lock, escrow);
        tokens = [new PayoutToken("USDC", 6), new PayoutToken("USDT", 6)];
        accounts = [alice, feeRecipient, keeper];
        handler = new EscrowHandler(escrow, swap, tokens, accounts, [bob, carol, makeAddr("newTreasury")]);
        targetContract(address(handler));
        bytes4[] memory actions = new bytes4[](9);
        actions[0] = EscrowHandler.deposit.selector;
        actions[1] = EscrowHandler.claim.selector;
        actions[2] = EscrowHandler.claimWithoutCredit.selector;
        actions[3] = EscrowHandler.depositByOutsider.selector;
        actions[4] = EscrowHandler.depositUnlocked.selector;
        actions[5] = EscrowHandler.donate.selector;
        actions[6] = EscrowHandler.depositRoundingUp.selector;
        actions[7] = EscrowHandler.claimWithSenderFee.selector;
        actions[8] = EscrowHandler.issuerBurn.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
    }

    // TEST-173 verifies: REQ-ESCROW-003, REQ-ESCROW-004, REQ-ESCROW-005, REQ-ESCROW-006, INV-061, Q-214, Q-389
    // Sources: 5.1 TEST-173 (escrow side), HYP-29
    function invariant_TEST_173_creditedEqualsClaimedPlusHeld() public view {
        for (uint256 t = 0; t < 2; ++t) {
            address token = address(tokens[t]);
            for (uint256 a = 0; a < 3; ++a) {
                address account = accounts[a];
                assertEq(
                    handler.credited(token, account),
                    handler.claimed(token, account) + escrow.claimable(token, account),
                    "credited = claimed + held"
                );
            }
        }
    }

    // TEST-173 verifies: REQ-ESCROW-003, REQ-ESCROW-004, REQ-ESCROW-006, INV-061, Q-214
    /// @notice The sum rule always holds; the escrow's balance equals the credits plus donations (surplus deposits
    /// included) minus what the issuer burned, so it covers every credit whenever nothing was burned.
    function invariant_TEST_173_totalIsSumAndBalanceCoversIt() public view {
        for (uint256 t = 0; t < 2; ++t) {
            address token = address(tokens[t]);
            uint256 sum;
            for (uint256 a = 0; a < 3; ++a) {
                sum += escrow.claimable(token, accounts[a]);
            }
            assertEq(escrow.totalClaimable(token), sum, "totalClaimable = sum of credits");
            assertEq(
                tokens[t].balanceOf(address(escrow)) + handler.burned(token),
                escrow.totalClaimable(token) + handler.donated(token),
                "balance + burned = credits + donations"
            );
        }
    }

    // TEST-173 verifies: REQ-ESCROW-002, REQ-ESCROW-004, REQ-ESCROW-005, REQ-ESCROW-015, ATTACK-118, INV-061, Q-214
    function invariant_TEST_173_onlyNamedRecipientAndOnlyLpVaultSwap() public view {
        assertEq(handler.wrongPayouts(), 0, "claim paid other than the whole credit to the named recipient");
        assertEq(handler.forbiddenSuccesses(), 0, "claim without credit or deposit outside LPVaultSwap under the Lock");
        assertEq(handler.refusalsWithEffect(), 0, "a refused call changed a credit");
        assertEq(handler.senderFeeClaimsPaid(), 0, "a claim paid a sender-side fee out of other credits");
    }
}
