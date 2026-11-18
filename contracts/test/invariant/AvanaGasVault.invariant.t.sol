// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaAccess} from "../../script/deploy/lib/AvanaAccess.sol";
import {AvanaGasVault} from "../../src/periphery/gas-vault/AvanaGasVault.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {AvanaGasVaultHandler} from "./handlers/AvanaGasVaultHandler.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

/// @title AvanaGasVaultInvariantTest
/// @notice TEST-335: random sequences of funding, gas spending, permissionless `topUp` and `topUpAll` by outsiders,
/// clock steps up to 30 h, governance adds, raises, unpauses and withdrawals, guardian removals, lowerings and pauses, and
/// privileged calls by strangers and by the guardian. After every call: ETH sent to a signer over any 24 h window never
/// passed the cap in force at each send; ETH left the vault only to then-listed signers (never above their target) or to
/// `TREASURY`; a removed signer received nothing; funded = held + sent + withdrawn; no forbidden call succeeded.
contract AvanaGasVaultInvariantTest is AvanaTest, HandlerReach {
    AvanaGasVault internal vault;
    AvanaGasVaultHandler internal handler;
    address internal treasury = makeAddr("treasury");
    address internal guardian = makeAddr("guardian");

    uint256 internal constant ACTIONS = 13;

    function setUp() public {
        vm.warp(1_800_000_000);
        vault = new AvanaGasVault(treasury, address(accessManager), guardian, 8);
        _bindAccess(AvanaAccess.Kind.GasVault, address(vault));
        address[] memory candidates = new address[](10);
        for (uint256 i; i < candidates.length; ++i) {
            candidates[i] = makeAddr(string.concat("signer", vm.toString(i)));
        }
        address[] memory strangers = new address[](3);
        strangers[0] = makeAddr("stranger0");
        strangers[1] = makeAddr("stranger1");
        strangers[2] = makeAddr("stranger2");
        handler = new AvanaGasVaultHandler(vault, governor, candidates, strangers);
        vm.deal(address(handler), 0);
        vm.prank(governor);
        vault.addSigner(candidates[0], 0.3 ether, 1 ether, 1 ether);
        vm.prank(governor);
        vault.addSigner(candidates[1], 0.3 ether, 1 ether, 1 ether);
        handler.fund(0, 10 ether);
        targetContract(address(handler));
        (bytes4[] memory actions,,) = _reachActions();
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
    }

    // TEST-082 verifies: TEST-007
    /// @notice What the handler does: over 32 fixed-seed runs of 50 calls, counts per action the calls that changed the
    /// vault's or an account's state; each action must change it in at least its floor of calls.
    function test_TEST_082_handlerReach() public {
        (bytes4[] memory actions, string[] memory names,) = _reachActions();
        address[] memory own = new address[](2);
        (own[0], own[1]) = (address(handler), address(this));
        Reach memory r =
            _replayLanded(address(handler), actions, AvanaGasVaultHandler.Skipped.selector, 32, 50, 0, own, true);
        uint256[] memory floors = new uint256[](ACTIONS);
        bool[] memory check = new bool[](ACTIONS);
        // fund, spend, warp and withdraw move only ETH balances or the clock, which are not storage slots: they are
        // counted as checks (a call that returned normally did its work).
        floors[0] = 95; // fund
        check[0] = true;
        floors[1] = 10; // spend: skipped while the drawn signer holds nothing
        check[1] = true;
        floors[2] = 5; // topUp: only a listed signer below its minimum with cap room
        floors[3] = 20; // topUpAll
        floors[4] = 95; // warp
        check[4] = true;
        floors[5] = 20; // addSigner
        floors[6] = 20; // setSignerConfig
        floors[7] = 25; // unpause: changes nothing while not paused
        floors[8] = 90; // withdraw
        check[8] = true;
        floors[9] = 15; // removeSigner
        floors[10] = 20; // tighten
        floors[11] = 40; // pause: changes nothing while paused
        floors[12] = 0; // forbidden: a check, every call refused
        check[12] = true;
        _check(r, names, new string[](0), floors, new uint256[](0), check);
    }

    function _reached() internal pure override returns (bool[] memory hit) {
        hit = new bool[](0);
    }

    function _reachActions()
        internal
        pure
        returns (bytes4[] memory actions, string[] memory names, int16[][] memory kinds)
    {
        (actions, names, kinds) = (new bytes4[](ACTIONS), new string[](ACTIONS), new int16[][](ACTIONS));
        (actions[0], names[0]) = (AvanaGasVaultHandler.fund.selector, "fund");
        kinds[0] = _kinds(2);
        (actions[1], names[1]) = (AvanaGasVaultHandler.spend.selector, "spend");
        kinds[1] = _kinds(2);
        (actions[2], names[2]) = (AvanaGasVaultHandler.topUp.selector, "topUp");
        kinds[2] = _kinds(2);
        (actions[3], names[3]) = (AvanaGasVaultHandler.topUpAll.selector, "topUpAll");
        kinds[3] = _kinds(1);
        (actions[4], names[4]) = (AvanaGasVaultHandler.warp.selector, "warp");
        kinds[4] = _kinds(1);
        (actions[5], names[5]) = (AvanaGasVaultHandler.addSigner.selector, "addSigner");
        kinds[5] = _kinds(4);
        (actions[6], names[6]) = (AvanaGasVaultHandler.setSignerConfig.selector, "setSignerConfig");
        kinds[6] = _kinds(4);
        (actions[7], names[7]) = (AvanaGasVaultHandler.unpause.selector, "unpause");
        kinds[7] = _kinds(0);
        (actions[8], names[8]) = (AvanaGasVaultHandler.withdraw.selector, "withdraw");
        kinds[8] = _kinds(1);
        (actions[9], names[9]) = (AvanaGasVaultHandler.removeSigner.selector, "removeSigner");
        kinds[9] = _kinds(1);
        (actions[10], names[10]) = (AvanaGasVaultHandler.tighten.selector, "tighten");
        kinds[10] = _kinds(4);
        (actions[11], names[11]) = (AvanaGasVaultHandler.pause.selector, "pause");
        kinds[11] = _kinds(0);
        (actions[12], names[12]) = (AvanaGasVaultHandler.forbidden.selector, "forbidden");
        kinds[12] = _kinds(3);
    }

    function _kinds(
        uint256 n
    ) internal pure returns (int16[] memory k) {
        k = new int16[](n);
        for (uint256 i; i < n; ++i) {
            k[i] = 256;
        }
    }

    function _calldata(
        bytes4 selector,
        uint256 seed
    ) internal pure override returns (bytes memory) {
        (bytes4[] memory actions,, int16[][] memory kinds) = _reachActions();
        for (uint256 k = 0; k < actions.length; ++k) {
            if (actions[k] == selector) return _typed(selector, kinds[k], seed);
        }
        return abi.encodePacked(selector);
    }

    // TEST-335 verifies: REQ-GASV-005, INV-111
    function invariant_TEST_335_sentInAnyWindowAtMostCap() public view {
        assertEq(handler.capBreaches(), 0, "a send took a 24 h window above the cap");
        uint256 n = handler.candidateCount();
        for (uint256 i; i < n; ++i) {
            address signer = handler.candidates(i);
            AvanaGasVault.SignerConfig memory c = vault.signerConfig(signer);
            uint256 window;
            uint256 sends;
            uint256 count = handler.sendCount(signer);
            for (uint256 k; k < count; ++k) {
                AvanaGasVaultHandler.Send memory s = handler.sendAt(signer, k);
                if (s.at + 1 days > block.timestamp) {
                    window += s.amount;
                    ++sends;
                }
            }
            assertEq(vault.sentInPeriod(signer), window, "vault window differs from the ledger");
            assertLe(sends, vault.MAX_SENDS_PER_PERIOD(), "more sends than slots in a window");
            if (vault.isSigner(signer) && sends > 0) {
                // Lowering the cap after sends is allowed; the cap then only bars new sends.
                (uint256 amount,) = vault.quoteTopUp(signer);
                assertLe(amount + window, window > c.periodCap ? window : c.periodCap, "quote above the cap room");
            }
        }
    }

    // TEST-335 verifies: REQ-GASV-004, REQ-GASV-010, REQ-GASV-012, INV-111
    function invariant_TEST_335_ethLeavesOnlyToListedSignersOrTreasury() public view {
        assertEq(handler.wrongPayments(), 0, "ETH reached an unlisted address, a signer above target, or a caller");
    }

    // TEST-335 verifies: REQ-GASV-003, REQ-GASV-012
    function invariant_TEST_335_fundedEqualsHeldPlusSentPlusWithdrawn() public view {
        assertEq(
            handler.funded(),
            address(vault).balance + handler.sent() + handler.withdrawn(),
            "funded = held + sent + out"
        );
    }

    // TEST-335 verifies: REQ-GASV-007, REQ-GASV-008, REQ-GASV-009, REQ-GASV-011, REQ-GASV-012
    function invariant_TEST_335_noForbiddenCallOrRuleBreach() public view {
        assertEq(handler.forbiddenSuccesses(), 0, "a privileged call by the wrong caller or a guardian raise succeeded");
        assertEq(handler.ruleBreaches(), 0, "a top-up succeeded while paused, unlisted, not due, or for 0");
        assertLe(vault.signers().length, vault.MAX_SIGNERS(), "allowlist above MAX_SIGNERS");
    }
}
