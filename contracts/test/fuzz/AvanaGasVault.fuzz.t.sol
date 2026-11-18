// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaAccess} from "../../script/deploy/lib/AvanaAccess.sol";
import {AvanaGasVault} from "../../src/periphery/gas-vault/AvanaGasVault.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

/// @notice AvanaGasVault top-up amount (2.24 `REQ-GASV-004`, `REQ-GASV-005`) for any configuration, signer balance,
/// vault balance and send history: a top-up sends exactly `min(targetBalance − balance, periodCap − sentInPeriod,
/// vault balance)`, never above the target, never more than the cap over the window, and only to the signer.
contract AvanaGasVaultFuzzTest is AvanaTest {
    AvanaGasVault internal vault;
    address internal treasury = makeAddr("treasury");
    address internal guardian = makeAddr("guardian");
    address internal signer = makeAddr("signer");
    address internal sink = makeAddr("sink");

    uint256 internal constant MAX80 = type(uint80).max;

    function setUp() public {
        vm.warp(1_800_000_000);
        vault = new AvanaGasVault(treasury, address(accessManager), guardian, 8);
        _bindAccess(AvanaAccess.Kind.GasVault, address(vault));
    }

    function _min(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // TEST-334 verifies: REQ-GASV-004, REQ-GASV-005
    function testFuzz_TEST_334_topUpSendsExactlyTheMinimumOfTheThreeTerms(
        uint256 minBalance,
        uint256 targetBalance,
        uint256 periodCap,
        uint256 balance,
        uint256 held,
        uint256 priorBalance,
        uint256 gap
    ) public {
        targetBalance = bound(targetBalance, 1, 1e24);
        minBalance = bound(minBalance, 1, targetBalance);
        periodCap = bound(periodCap, 1, MAX80);
        held = bound(held, 0, 1e25);
        gap = bound(gap, 0, 2 days);
        vm.deal(address(vault), held);
        vm.prank(governor);
        vault.addSigner(signer, minBalance, targetBalance, periodCap);

        // An earlier top-up `gap` seconds ago, when it was due and could send.
        priorBalance = bound(priorBalance, 0, minBalance - 1);
        vm.deal(signer, priorBalance);
        uint256 sentBefore;
        (uint256 q,) = vault.quoteTopUp(signer);
        if (q > 0) sentBefore = vault.topUp(signer);
        vm.warp(block.timestamp + gap);
        uint256 inWindow = gap < 1 days ? sentBefore : 0;
        assertEq(vault.sentInPeriod(signer), inWindow, "window sum");

        balance = bound(balance, 0, minBalance - 1);
        vm.deal(signer, balance);
        uint256 vaultBefore = address(vault).balance;
        uint256 expected = _min(
            _min(
                targetBalance > balance ? targetBalance - balance : 0, periodCap > inWindow ? periodCap - inWindow : 0
            ),
            vaultBefore
        );
        (uint256 quoted, uint256 requested) = vault.quoteTopUp(signer);
        assertEq(quoted, expected, "quote");
        assertEq(requested, targetBalance - balance, "requested");
        if (expected == 0) {
            vm.expectRevert();
            vault.topUp(signer);
            return;
        }
        uint256 callerBefore = address(this).balance;
        assertEq(vault.topUp(signer), expected, "sent");
        assertEq(signer.balance, balance + expected, "signer");
        assertLe(signer.balance, targetBalance, "above target");
        assertLe(vault.sentInPeriod(signer), periodCap, "above cap");
        assertEq(address(vault).balance, vaultBefore - expected, "vault");
        assertEq(address(this).balance, callerBefore, "caller paid");
    }

    // TEST-334 verifies: REQ-GASV-005
    function testFuzz_TEST_334_capHoldsOverEveryWindowOfASendSequence(
        uint256 periodCap,
        uint64[8] memory gaps,
        uint256[8] memory spends
    ) public {
        periodCap = bound(periodCap, 1, 10 ether);
        vm.deal(address(vault), 1000 ether);
        vm.prank(governor);
        vault.addSigner(signer, 1 ether, 1 ether, periodCap);
        uint256[8] memory at;
        uint256[8] memory amount;
        uint256 n;
        for (uint256 i; i < 8; ++i) {
            vm.warp(block.timestamp + bound(gaps[i], 0, 30 hours));
            uint256 burn = bound(spends[i], 0, signer.balance);
            vm.prank(signer);
            (bool ok,) = sink.call{value: burn}("");
            assertTrue(ok);
            (uint256 q,) = vault.quoteTopUp(signer);
            if (q == 0) continue;
            at[n] = block.timestamp;
            amount[n] = vault.topUp(signer);
            ++n;
        }
        // The heaviest window of length PERIOD ends at a send: check the window ending at each one.
        for (uint256 j; j < n; ++j) {
            uint256 sum;
            uint256 sends;
            for (uint256 k; k <= j; ++k) {
                if (at[k] + 1 days > at[j]) {
                    sum += amount[k];
                    ++sends;
                }
            }
            assertLe(sum, periodCap, "cap over a window");
            assertLe(sends, 4, "sends over a window");
        }
    }

    receive() external payable {}
}
