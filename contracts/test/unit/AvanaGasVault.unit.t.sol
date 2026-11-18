// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaAccess} from "../../script/deploy/lib/AvanaAccess.sol";
import {AvanaGasVault} from "../../src/periphery/gas-vault/AvanaGasVault.sol";
import {IAvanaGasVault} from "../../src/periphery/gas-vault/IAvanaGasVault.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

/// @dev A signer whose `receive` re-enters the vault (`topUp` or `topUpAll`) and records the revert.
contract ReentrantSigner {
    IAvanaGasVault internal immutable vault;
    bool public reentered;
    bytes public reason;
    bool internal useAll;

    constructor(
        IAvanaGasVault v
    ) {
        vault = v;
    }

    function setUseAll(
        bool all
    ) external {
        useAll = all;
    }

    function burn(
        address to,
        uint256 amount
    ) external {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "burn");
    }

    receive() external payable {
        if (reentered) return;
        reentered = true;
        try this.reenter() {}
        catch (bytes memory r) {
            reason = r;
        }
    }

    function reenter() external {
        if (useAll) vault.topUpAll();
        else vault.topUp(address(this));
    }
}

/// @dev A signer that refuses ETH.
contract RefusingSigner {
    receive() external payable {
        revert("no");
    }
}

/// @dev A signer whose `receive` burns every gas unit it is given.
contract GasBurningSigner {
    receive() external payable {
        while (true) {}
    }
}

/// @notice AvanaGasVault (2.24): the top-up rule and its three caps, the exact 24 h window, `topUpAll`, reentry, the
/// timelock and guardian split, tighten-only, the allowlist bound, pause and withdrawal to `TREASURY` only.
contract AvanaGasVaultUnitTest is AvanaTest {
    AvanaGasVault internal vault;
    address internal treasury = makeAddr("treasury");
    address internal guardian = makeAddr("guardian");
    address internal primary = makeAddr("primary");
    address internal standby = makeAddr("standby");
    address internal stranger = makeAddr("stranger");
    address internal sink = makeAddr("sink");

    uint256 internal constant MIN = 0.3 ether;
    uint256 internal constant TARGET = 1 ether;
    uint256 internal constant CAP = 1 ether;

    function setUp() public {
        vm.warp(1_800_000_000);
        vault = new AvanaGasVault(treasury, address(accessManager), guardian, 8);
        _bindAccess(AvanaAccess.Kind.GasVault, address(vault));
        vm.deal(address(this), 100 ether);
        vault.fund{value: 50 ether}();
        vm.startPrank(governor);
        vault.addSigner(primary, MIN, TARGET, CAP);
        vault.addSigner(standby, MIN, TARGET, CAP);
        vm.stopPrank();
    }

    /// @dev Moves `amount` out of a plain signer, as gas spending would.
    function _spend(
        address signer,
        uint256 amount
    ) internal {
        vm.prank(signer);
        (bool ok,) = sink.call{value: amount}("");
        assertTrue(ok);
    }

    // ─── Deployment ───

    // TEST-333 verifies: REQ-GASV-001, REQ-GASV-002
    function test_TEST_333_constructorFixesImmutablesAndRefusesBadInputs() public {
        assertEq(vault.TREASURY(), treasury);
        assertEq(IAccessManaged(address(vault)).authority(), address(accessManager));
        assertEq(vault.GUARDIAN(), guardian);
        assertEq(vault.MAX_SIGNERS(), 8);
        assertEq(vault.PERIOD(), 86_400);
        assertEq(vault.MAX_SENDS_PER_PERIOD(), 4);
        vm.expectRevert(IAvanaGasVault.InvalidAddress.selector);
        new AvanaGasVault(address(0), address(accessManager), guardian, 8);
        vm.expectRevert(IAvanaGasVault.InvalidAddress.selector);
        new AvanaGasVault(treasury, address(0), guardian, 8);
        vm.expectRevert(IAvanaGasVault.InvalidAddress.selector);
        new AvanaGasVault(treasury, address(accessManager), address(0), 8);
        vm.expectRevert(IAvanaGasVault.InvalidAddress.selector);
        new AvanaGasVault(treasury, treasury, guardian, 8);
        vm.expectRevert(IAvanaGasVault.InvalidAddress.selector);
        new AvanaGasVault(treasury, address(accessManager), treasury, 8);
        vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.InvalidMaxSigners.selector, 0));
        new AvanaGasVault(treasury, address(accessManager), guardian, 0);
        vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.InvalidMaxSigners.selector, 9));
        new AvanaGasVault(treasury, address(accessManager), guardian, 9);
        new AvanaGasVault(treasury, address(accessManager), guardian, 1);
    }

    // TEST-333 verifies: REQ-GASV-003
    function test_TEST_333_fundAndReceiveFromAnyone() public {
        vm.deal(stranger, 2 ether);
        vm.expectEmit(true, false, false, true, address(vault));
        emit IAvanaGasVault.Funded(stranger, 1 ether);
        vm.prank(stranger);
        vault.fund{value: 1 ether}();
        vm.expectEmit(true, false, false, true, address(vault));
        emit IAvanaGasVault.Funded(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(vault).balance, 52 ether);
    }

    // ─── topUp ───

    // TEST-333 verifies: REQ-GASV-004, REQ-GASV-015
    function test_TEST_333_topUp_revertsNotBelowMinimum() public {
        vm.deal(primary, MIN);
        vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.NotBelowMinimum.selector, primary, MIN, MIN));
        vault.topUp(primary);
        vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.UnknownSigner.selector, stranger));
        vault.topUp(stranger);
    }

    // TEST-333 verifies: REQ-GASV-004
    function test_TEST_333_topUp_fillsToTarget() public {
        vm.deal(primary, 0.2 ether);
        vm.expectEmit(true, true, false, true, address(vault));
        emit IAvanaGasVault.ToppedUp(primary, stranger, 0.8 ether, 0.8 ether);
        vm.prank(stranger);
        assertEq(vault.topUp(primary), 0.8 ether);
        assertEq(primary.balance, TARGET);
        assertEq(vault.sentInPeriod(primary), 0.8 ether);
        assertEq(address(vault).balance, 49.2 ether);
        // A second call finds the signer at its target.
        vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.NotBelowMinimum.selector, primary, TARGET, MIN));
        vault.topUp(primary);
    }

    // TEST-333 verifies: REQ-GASV-004, REQ-GASV-005, ATTACK-207, ATTACK-208
    function test_TEST_333_topUp_cappedByPeriod() public {
        vm.deal(primary, 0.2 ether);
        vault.topUp(primary); // 0.8 sent
        _spend(primary, 0.9 ether); // at 0.1
        (uint256 amount, uint256 requested) = vault.quoteTopUp(primary);
        assertEq(requested, 0.9 ether);
        assertEq(amount, 0.2 ether);
        vm.expectEmit(true, true, false, true, address(vault));
        emit IAvanaGasVault.ToppedUp(primary, address(this), 0.2 ether, 0.9 ether);
        assertEq(vault.topUp(primary), 0.2 ether);
        _spend(primary, 0.25 ether);
        vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.NothingToSend.selector, primary, 0.95 ether, 0, 49 ether));
        vault.topUp(primary);
        // The window is exact: one second before the first send leaves it, still nothing.
        vm.warp(block.timestamp + 86_399);
        vm.expectRevert();
        vault.topUp(primary);
        // At 24 h the first send (0.8) leaves the window; the 0.2 sent at the same time also leaves.
        vm.warp(block.timestamp + 1);
        assertEq(vault.sentInPeriod(primary), 0);
        assertEq(vault.topUp(primary), 0.95 ether);
    }

    // TEST-333 verifies: REQ-GASV-005
    function test_TEST_333_topUp_capHoldsOverAnyWindowNotPerCalendarPeriod() public {
        uint256 t0 = block.timestamp;
        vm.prank(governor);
        vault.setSignerConfig(primary, 0.05 ether, 0.1 ether, CAP);
        assertEq(vault.topUp(primary), 0.1 ether); // at t0
        vm.warp(t0 + 23 hours);
        vm.prank(governor);
        vault.setSignerConfig(primary, MIN, TARGET, CAP);
        _spend(primary, 0.1 ether);
        assertEq(vault.topUp(primary), 0.9 ether); // cap now used up
        _spend(primary, 0.9 ether);
        vm.expectRevert();
        vault.topUp(primary);
        // At t0 + 24 h only the first send leaves the window. A period reset at t0 + 24 h would allow a full cap here;
        // the window (t0, t0 + 24 h] still holds the 0.9 sent at t0 + 23 h, so only the 0.1 left is sent.
        vm.warp(t0 + 24 hours);
        assertEq(vault.sentInPeriod(primary), 0.9 ether);
        assertEq(vault.topUp(primary), 0.1 ether);
        assertEq(vault.sentInPeriod(primary), CAP);
    }

    // TEST-333 verifies: REQ-GASV-005
    function test_TEST_333_topUp_atMostFourSendsPerWindow() public {
        vm.prank(governor);
        vault.setSignerConfig(primary, MIN, TARGET, 10 ether);
        vm.deal(primary, 0);
        for (uint256 i; i < 4; ++i) {
            vault.topUp(primary);
            _spend(primary, 1 ether);
            vm.warp(block.timestamp + 1 hours);
        }
        assertEq(vault.sentInPeriod(primary), 4 ether);
        (uint256 amount,) = vault.quoteTopUp(primary);
        assertEq(amount, 0);
        vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.NothingToSend.selector, primary, 1 ether, 0, 46 ether));
        vault.topUp(primary);
        // The oldest slot frees 24 h after its send.
        vm.warp(block.timestamp + 20 hours);
        assertEq(vault.topUp(primary), 1 ether);
    }

    // TEST-333 verifies: REQ-GASV-004, REQ-GASV-017
    function test_TEST_333_topUp_cappedByVaultBalance() public {
        vm.prank(governor);
        vault.withdraw(49.5 ether);
        vm.deal(primary, 0);
        assertEq(vault.topUp(primary), 0.5 ether);
        assertEq(address(vault).balance, 0);
        vm.deal(standby, 0);
        vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.NothingToSend.selector, standby, 1 ether, 1 ether, 0));
        vault.topUp(standby);
    }

    // TEST-333 verifies: REQ-GASV-004, ATTACK-207
    function test_TEST_333_topUp_paysSignerNotCaller() public {
        vm.deal(primary, 0);
        uint256 callerBefore = stranger.balance;
        vm.prank(stranger);
        vault.topUp(primary);
        assertEq(stranger.balance, callerBefore);
        assertEq(primary.balance, 1 ether);
    }

    // TEST-333 verifies: REQ-GASV-004
    function test_TEST_333_topUp_loweredTargetBelowBalanceSendsNothing() public {
        vm.deal(primary, 0.25 ether);
        vm.prank(guardian);
        vault.tightenSigner(primary, MIN, 0.3 ether, CAP);
        // 0.25 < min 0.3 but the target 0.3 leaves 0.05.
        assertEq(vault.topUp(primary), 0.05 ether);
        vm.prank(guardian);
        vault.tightenSigner(primary, 0.3 ether, 0.3 ether, CAP);
        _spend(primary, 0.1 ether);
        assertEq(vault.topUp(primary), 0.1 ether);
    }

    // TEST-333 verifies: REQ-GASV-013
    function test_TEST_333_topUp_reentrantSignerBlocked() public {
        ReentrantSigner r = new ReentrantSigner(vault);
        vm.prank(governor);
        vault.addSigner(address(r), MIN, TARGET, CAP);
        assertEq(vault.topUp(address(r)), 1 ether);
        assertTrue(r.reentered());
        assertEq(bytes4(r.reason()), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(address(r).balance, 1 ether);
        assertEq(vault.sentInPeriod(address(r)), 1 ether);
    }

    // TEST-333 verifies: REQ-GASV-004, REQ-GASV-015
    function test_TEST_333_topUp_refusingSignerReverts() public {
        RefusingSigner r = new RefusingSigner();
        vm.prank(governor);
        vault.addSigner(address(r), MIN, TARGET, CAP);
        vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.SendFailed.selector, address(r), 1 ether));
        vault.topUp(address(r));
        assertEq(vault.sentInPeriod(address(r)), 0);
    }

    // ─── topUpAll ───

    // TEST-333 verifies: REQ-GASV-013
    /// @notice A recipient's code gets at most 100,000 gas: a signer that burns all it is given fails its transfer
    /// (`SendFailed` from `topUp`, `TopUpFailed` from `topUpAll`) without consuming the caller's gas, and the others are
    /// still paid.
    function test_TEST_333_transferGasIsBounded() public {
        assertEq(vault.TRANSFER_GAS(), 100_000);
        GasBurningSigner b = new GasBurningSigner();
        vm.prank(governor);
        vault.addSigner(address(b), MIN, TARGET, CAP);
        uint256 before = gasleft();
        vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.SendFailed.selector, address(b), 1 ether));
        vault.topUp(address(b));
        assertLt(before - gasleft(), 250_000, "topUp burned the caller's gas");
        vm.deal(primary, 0);
        vm.deal(standby, TARGET);
        before = gasleft();
        (uint256 count,) = vault.topUpAll();
        assertLt(before - gasleft(), 400_000, "topUpAll burned the caller's gas");
        assertEq(count, 1);
        assertEq(primary.balance, 1 ether);
        assertEq(vault.sentInPeriod(address(b)), 0, "failed send recorded");
    }

    // TEST-333 verifies: REQ-GASV-006
    function test_TEST_333_topUpAll_skipsFunded() public {
        vm.deal(primary, 0.1 ether);
        vm.deal(standby, 0.5 ether);
        (uint256 count, uint256 total) = vault.topUpAll();
        assertEq(count, 1);
        assertEq(total, 0.9 ether);
        assertEq(primary.balance, 1 ether);
        assertEq(standby.balance, 0.5 ether);
        (count, total) = vault.topUpAll();
        assertEq(count, 0);
        assertEq(total, 0);
    }

    // TEST-333 verifies: REQ-GASV-006
    function test_TEST_333_topUpAll_skipsRefusingAndCappedSigners() public {
        RefusingSigner r = new RefusingSigner();
        vm.prank(governor);
        vault.addSigner(address(r), MIN, TARGET, CAP);
        vm.deal(primary, 0);
        vm.deal(standby, 0);
        vault.topUp(standby);
        _spend(standby, 1 ether); // capped for 24 h
        vm.expectEmit(true, false, false, true, address(vault));
        emit IAvanaGasVault.TopUpFailed(address(r), 1 ether);
        (uint256 count, uint256 total) = vault.topUpAll();
        assertEq(count, 1);
        assertEq(total, 1 ether);
        assertEq(primary.balance, 1 ether);
        assertEq(vault.sentInPeriod(address(r)), 0, "failed send recorded");
    }

    // TEST-333 verifies: REQ-GASV-006, REQ-GASV-013
    function test_TEST_333_topUpAll_reentryBlocked() public {
        ReentrantSigner r = new ReentrantSigner(vault);
        r.setUseAll(true);
        vm.prank(governor);
        vault.addSigner(address(r), MIN, TARGET, CAP);
        (uint256 count,) = vault.topUpAll();
        assertEq(count, 3);
        assertEq(bytes4(r.reason()), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
    }

    // ─── Signers ───

    // TEST-333 verifies: REQ-GASV-007, REQ-GASV-016
    function test_TEST_333_addSigner_onlyTimelock() public {
        address s = makeAddr("s");
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardian));
        vault.addSigner(s, MIN, TARGET, CAP);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vault.addSigner(s, MIN, TARGET, CAP);
        vm.expectEmit(true, false, false, true, address(vault));
        emit IAvanaGasVault.SignerAdded(s, MIN, TARGET, CAP);
        vm.prank(governor);
        vault.addSigner(s, MIN, TARGET, CAP);
        assertTrue(vault.isSigner(s));
        assertEq(vault.signers().length, 3);
    }

    // TEST-333 verifies: REQ-GASV-007, REQ-GASV-016
    function test_TEST_333_addSigner_refusesBadSignersAndConfigs() public {
        address[6] memory bad = [address(0), address(vault), treasury, address(accessManager), guardian, primary];
        vm.startPrank(governor);
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.InvalidSigner.selector, bad[i]));
            vault.addSigner(bad[i], MIN, TARGET, CAP);
        }
        address s = makeAddr("s");
        vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.InvalidConfig.selector, 0, TARGET, CAP));
        vault.addSigner(s, 0, TARGET, CAP);
        vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.InvalidConfig.selector, MIN, TARGET, 0));
        vault.addSigner(s, MIN, TARGET, 0);
        vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.InvalidConfig.selector, TARGET + 1, TARGET, CAP));
        vault.addSigner(s, TARGET + 1, TARGET, CAP);
        uint256 big = uint256(type(uint80).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.InvalidConfig.selector, MIN, big, CAP));
        vault.addSigner(s, MIN, big, CAP);
        vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.InvalidConfig.selector, MIN, TARGET, big));
        vault.addSigner(s, MIN, TARGET, big);
        vault.addSigner(s, MIN, MIN, type(uint80).max);
        vm.stopPrank();
    }

    // TEST-333 verifies: REQ-GASV-007
    function test_TEST_333_maxSigners() public {
        vm.startPrank(governor);
        for (uint256 i; i < 6; ++i) {
            vault.addSigner(address(uint160(0xA000 + i)), MIN, TARGET, CAP);
        }
        vm.expectRevert(IAvanaGasVault.TooManySigners.selector);
        vault.addSigner(address(0xB000), MIN, TARGET, CAP);
        vm.stopPrank();
        AvanaGasVault small = new AvanaGasVault(treasury, address(accessManager), guardian, 1);
        _bindAccess(AvanaAccess.Kind.GasVault, address(small));
        vm.startPrank(governor);
        small.addSigner(primary, MIN, TARGET, CAP);
        vm.expectRevert(IAvanaGasVault.TooManySigners.selector);
        small.addSigner(standby, MIN, TARGET, CAP);
        // A removal frees the seat.
        small.removeSigner(primary);
        small.addSigner(standby, MIN, TARGET, CAP);
        vm.stopPrank();
    }

    // TEST-333 verifies: REQ-GASV-008
    function test_TEST_333_setSignerConfig_onlyTimelockEitherDirection() public {
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardian));
        vault.setSignerConfig(primary, MIN, 2 ether, 2 ether);
        vm.expectEmit(true, true, false, true, address(vault));
        emit IAvanaGasVault.SignerConfigChanged(primary, governor, MIN, 2 ether, 2 ether);
        vm.prank(governor);
        vault.setSignerConfig(primary, MIN, 2 ether, 2 ether);
        IAvanaGasVault.SignerConfig memory c = vault.signerConfig(primary);
        assertEq(c.targetBalance, 2 ether);
        assertEq(c.periodCap, 2 ether);
        vm.prank(governor);
        vault.setSignerConfig(primary, 0.1 ether, 0.2 ether, 0.2 ether);
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.UnknownSigner.selector, stranger));
        vault.setSignerConfig(stranger, MIN, TARGET, CAP);
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.InvalidConfig.selector, MIN, TARGET, 0));
        vault.setSignerConfig(primary, MIN, TARGET, 0);
    }

    // TEST-333 verifies: REQ-GASV-010, ATTACK-208
    function test_TEST_333_removeSigner_guardianImmediate() public {
        address third = makeAddr("third");
        vm.prank(governor);
        vault.addSigner(third, MIN, TARGET, CAP);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vault.removeSigner(primary);
        vm.expectEmit(true, true, false, false, address(vault));
        emit IAvanaGasVault.SignerRemoved(primary, guardian);
        vm.prank(guardian);
        vault.removeSigner(primary);
        assertFalse(vault.isSigner(primary));
        address[] memory list = vault.signers();
        assertEq(list.length, 2);
        assertEq(list[0], third);
        assertEq(list[1], standby);
        // The moved signer keeps working and can itself be removed.
        vm.prank(governor);
        vault.removeSigner(third);
        assertEq(vault.signers()[0], standby);
        vm.deal(primary, 0);
        vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.UnknownSigner.selector, primary));
        vault.topUp(primary);
        (uint256 count,) = vault.topUpAll();
        assertEq(primary.balance, 0, "removed signer paid");
        assertEq(count, 1);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.UnknownSigner.selector, primary));
        vault.removeSigner(primary);
    }

    // TEST-333 verifies: REQ-GASV-005, REQ-GASV-010
    function test_TEST_333_reAddedSignerKeepsItsWindow() public {
        vm.deal(primary, 0);
        vault.topUp(primary);
        vm.prank(guardian);
        vault.removeSigner(primary);
        vm.prank(governor);
        vault.addSigner(primary, MIN, TARGET, CAP);
        assertEq(vault.sentInPeriod(primary), 1 ether);
        _spend(primary, 1 ether);
        vm.expectRevert();
        vault.topUp(primary);
    }

    // TEST-333 verifies: REQ-GASV-009, REQ-GASV-016, ATTACK-208
    function test_TEST_333_guardian_cannotRaise() public {
        vm.startPrank(guardian);
        vm.expectRevert(IAvanaGasVault.NotTighter.selector);
        vault.tightenSigner(primary, MIN + 1, TARGET, CAP);
        vm.expectRevert(IAvanaGasVault.NotTighter.selector);
        vault.tightenSigner(primary, MIN, TARGET + 1, CAP);
        vm.expectRevert(IAvanaGasVault.NotTighter.selector);
        vault.tightenSigner(primary, MIN, TARGET, CAP + 1);
        vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.InvalidConfig.selector, MIN, MIN - 1, CAP));
        vault.tightenSigner(primary, MIN, MIN - 1, CAP);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardian));
        vault.setSignerConfig(primary, MIN, TARGET, CAP);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardian));
        vault.addSigner(stranger, MIN, TARGET, CAP);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardian));
        vault.unpause();
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardian));
        vault.withdraw(1);
        // Lowering every value to 0 is allowed: the signer is then never topped up.
        vm.expectEmit(true, true, false, true, address(vault));
        emit IAvanaGasVault.SignerConfigChanged(primary, guardian, 0, 0, 0);
        vault.tightenSigner(primary, 0, 0, 0);
        vm.stopPrank();
        vm.deal(primary, 0);
        vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.NotBelowMinimum.selector, primary, 0, 0));
        vault.topUp(primary);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vault.tightenSigner(standby, 0, 0, 0);
        vm.prank(governor);
        vault.tightenSigner(standby, 0.1 ether, 0.5 ether, 0.5 ether);
    }

    // ─── Pause and withdrawal ───

    // TEST-333 verifies: REQ-GASV-011, REQ-GASV-015
    function test_TEST_333_pause_blocksTopUp() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vault.pause();
        vm.expectEmit(false, true, false, true, address(vault));
        emit IAvanaGasVault.PauseChanged(true, guardian);
        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused());
        vm.deal(primary, 0);
        vm.expectRevert(IAvanaGasVault.VaultPaused.selector);
        vault.topUp(primary);
        vm.expectRevert(IAvanaGasVault.VaultPaused.selector);
        vault.topUpAll();
        (uint256 amount, uint256 requested) = vault.quoteTopUp(primary);
        assertEq(amount, 0);
        assertEq(requested, 1 ether);
        // Funding, withdrawal and the guardian's removals stay open.
        vault.fund{value: 1 ether}();
        vm.prank(governor);
        vault.withdraw(1 ether);
        vm.prank(guardian);
        vault.removeSigner(standby);
    }

    // TEST-333 verifies: REQ-GASV-011
    function test_TEST_333_unpause_onlyTimelock() public {
        vm.prank(governor);
        vault.pause();
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardian));
        vault.unpause();
        vm.expectEmit(false, true, false, true, address(vault));
        emit IAvanaGasVault.PauseChanged(false, governor);
        vm.prank(governor);
        vault.unpause();
        assertFalse(vault.paused());
        vm.deal(primary, 0);
        assertEq(vault.topUp(primary), 1 ether);
    }

    // TEST-333 verifies: REQ-GASV-012
    function test_TEST_333_withdraw_onlyTreasury() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vault.withdraw(1 ether);
        vm.expectEmit(false, false, false, true, address(vault));
        emit IAvanaGasVault.Withdrawn(10 ether);
        vm.prank(governor);
        vault.withdraw(10 ether);
        assertEq(treasury.balance, 10 ether);
        assertEq(governor.balance, 0);
        vm.startPrank(governor);
        vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.InvalidWithdrawal.selector, 0, 40 ether));
        vault.withdraw(0);
        vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.InvalidWithdrawal.selector, 41 ether, 40 ether));
        vault.withdraw(41 ether);
        vault.withdraw(40 ether);
        vm.stopPrank();
        assertEq(treasury.balance, 50 ether);
    }

    // TEST-333 verifies: REQ-GASV-011, REQ-GASV-012
    /// @notice No ETH is ever locked: after the vault is retired (paused, every signer removed) and ETH still arrives,
    /// the timelock withdraws the whole balance to TREASURY.
    function test_TEST_333_retiredVaultReturnsAllEth() public {
        vm.startPrank(guardian);
        vault.pause();
        vault.removeSigner(primary);
        vault.removeSigner(standby);
        vm.stopPrank();
        vm.deal(stranger, 3 ether);
        vm.prank(stranger);
        (bool ok,) = address(vault).call{value: 3 ether}("");
        assertTrue(ok);
        uint256 held = address(vault).balance;
        uint256 before = treasury.balance;
        vm.prank(governor);
        vault.withdraw(held);
        assertEq(address(vault).balance, 0);
        assertEq(treasury.balance, before + held);
    }

    // TEST-333 verifies: REQ-GASV-012
    function test_TEST_333_withdraw_refusingTreasuryReverts() public {
        RefusingSigner t = new RefusingSigner();
        AvanaGasVault v = new AvanaGasVault(address(t), address(accessManager), guardian, 8);
        _bindAccess(AvanaAccess.Kind.GasVault, address(v));
        v.fund{value: 1 ether}();
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IAvanaGasVault.SendFailed.selector, address(t), 1 ether));
        v.withdraw(1 ether);
    }

    // ─── Views ───

    // TEST-333 verifies: REQ-GASV-014
    function test_TEST_333_viewsOfUnlistedAndNotDue() public {
        IAvanaGasVault.SignerConfig memory c = vault.signerConfig(stranger);
        assertEq(c.minBalance + c.targetBalance + c.periodCap, 0);
        (uint256 amount, uint256 requested) = vault.quoteTopUp(stranger);
        assertEq(amount + requested, 0);
        vm.deal(primary, MIN);
        (amount, requested) = vault.quoteTopUp(primary);
        assertEq(amount + requested, 0);
        assertEq(vault.sentInPeriod(stranger), 0);
    }
}
