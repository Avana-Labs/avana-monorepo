// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PayoutEscrow} from "../../src/liquidation/payout-escrow/PayoutEscrow.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {PayoutDepositor} from "../utils/mocks/PayoutEscrowActors.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {EscrowHandler} from "./handlers/EscrowHandler.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";

/// @title PayoutEscrowInvariantTest
/// @notice Escrow side of TEST-173: random sequences of failed-payout deposits by LPVaultSwap under the Lock (one
/// token with an issuer fee switched on and off), claims by credited accounts to chosen and blocklisted recipients,
/// claims by addresses without a credit, deposits by outsiders and by LPVaultSwap without the Lock, and dust
/// donations. After every call, for every token and account: credited = claimed + held; `totalClaimable` is the sum
/// of the credits; the escrow's balance is `totalClaimable` plus the donations; no claim paid other than the whole
/// credit to the named recipient; nothing but LPVaultSwap under the Lock deposited.
/// @dev The liquidation side (LPVaultSwap's routed payouts failing for reverting and blocklisted recipients) is outside
/// this suite; the handler's `deposit` stands in for LPVaultSwap's deposits.
contract PayoutEscrowInvariantTest is AvanaTest, HandlerReach {
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

    // TEST-082 verifies: TEST-007
    /// @notice What the handler does: over 32 fixed-seed runs of 50 calls from set-up, counts per action the calls that
    /// changed the state of a contract other than the handler and this test, the skipped and failed calls and the
    /// calls that returned without changing anything; each action must change the state in at least its floor of
    /// calls (`forge test -vv` prints the table).
    function test_TEST_082_handlerReach() public {
        (bytes4[] memory actions, string[] memory names,) = _reachActions();
        address[] memory own = new address[](2);
        (own[0], own[1]) = (address(handler), address(this));
        Reach memory r = _replayLanded(address(handler), actions, EscrowHandler.Skipped.selector, 32, 50, 0, own, true);
        _check(r, names, new string[](0), _floors(9, 0), new uint256[](0));
    }

    function _reached() internal pure override returns (bool[] memory hit) {
        hit = new bool[](0);
    }

    /// @dev The targeted actions, their names and the type of each of their parameters (see `_typed`).
    function _reachActions() internal pure returns (bytes4[] memory actions, string[] memory names, int16[][] memory kinds) {
        (actions, names, kinds) = (new bytes4[](9), new string[](9), new int16[][](9));
        (actions[0], names[0]) = (EscrowHandler.deposit.selector, "deposit");
        kinds[0] = new int16[](4);
        kinds[0][0] = 256;
        kinds[0][1] = 256;
        kinds[0][2] = 256;
        kinds[0][3] = 256;
        (actions[1], names[1]) = (EscrowHandler.claim.selector, "claim");
        kinds[1] = new int16[](4);
        kinds[1][0] = 256;
        kinds[1][1] = 256;
        kinds[1][2] = 256;
        kinds[1][3] = 1;
        (actions[2], names[2]) = (EscrowHandler.claimWithoutCredit.selector, "claimWithoutCredit");
        kinds[2] = new int16[](2);
        kinds[2][0] = 256;
        kinds[2][1] = 160;
        (actions[3], names[3]) = (EscrowHandler.depositByOutsider.selector, "depositByOutsider");
        kinds[3] = new int16[](4);
        kinds[3][0] = 256;
        kinds[3][1] = 256;
        kinds[3][2] = 160;
        kinds[3][3] = 256;
        (actions[4], names[4]) = (EscrowHandler.depositUnlocked.selector, "depositUnlocked");
        kinds[4] = new int16[](2);
        kinds[4][0] = 256;
        kinds[4][1] = 256;
        (actions[5], names[5]) = (EscrowHandler.donate.selector, "donate");
        kinds[5] = new int16[](2);
        kinds[5][0] = 256;
        kinds[5][1] = 256;
        (actions[6], names[6]) = (EscrowHandler.depositRoundingUp.selector, "depositRoundingUp");
        kinds[6] = new int16[](3);
        kinds[6][0] = 256;
        kinds[6][1] = 256;
        kinds[6][2] = 256;
        (actions[7], names[7]) = (EscrowHandler.claimWithSenderFee.selector, "claimWithSenderFee");
        kinds[7] = new int16[](3);
        kinds[7][0] = 256;
        kinds[7][1] = 256;
        kinds[7][2] = 256;
        (actions[8], names[8]) = (EscrowHandler.issuerBurn.selector, "issuerBurn");
        kinds[8] = new int16[](2);
        kinds[8][0] = 256;
        kinds[8][1] = 256;
    }

    function _calldata(bytes4 selector, uint256 seed) internal pure override returns (bytes memory) {
        (bytes4[] memory actions,, int16[][] memory kinds) = _reachActions();
        for (uint256 k = 0; k < actions.length; ++k) {
            if (actions[k] == selector) return _typed(selector, kinds[k], seed);
        }
        return abi.encodePacked(selector);
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
