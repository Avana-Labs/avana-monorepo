// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaGasVault} from "../../src/periphery/gas-vault/AvanaGasVault.sol";
import {IAvanaGasVault} from "../../src/periphery/gas-vault/IAvanaGasVault.sol";
import {GasCalibration} from "../utils/GasCalibration.sol";
import {Test} from "forge-std/Test.sol";

/// @title AvanaGasVaultGasTest
/// @notice Gas of the AvanaGasVault's permissionless calls (2.23), each as its own transaction (`isolate = true`,
/// `GasCalibration._txGas`: intrinsic gas included, every account and slot cold), recorded with `vm.snapshotValue`
/// (group `AvanaGasVault`): one `topUp`; `topUpAll` over `MAX_SIGNERS_LIMIT` = 8 signers when all are due (the worst
/// case `MAX_SIGNERS` bounds, `REQ-GASV-006`), both once their send slots are in use (the budget case) and on their
/// first sends, and when none is due; and `topUpAll` with 8 due signers whose accounts are
/// empty (balance and nonce 0, so each transfer pays the new-account charge), which a keeper signer that has sent a
/// transaction never is. A due signer here holds 1 wei, so its account exists.
/// forge-config: default.isolate = true
contract AvanaGasVaultGasTest is Test, GasCalibration {
    /// @notice DESIGN section 6 bound for `topUpAll` with 8 signers.
    uint256 internal constant TOP_UP_ALL_BUDGET = 300_000;

    AvanaGasVault internal vault;
    address internal timelock = makeAddr("timelock");
    address internal keeper = makeAddr("keeper");
    address[8] internal signerList;

    function setUp() public {
        vm.warp(1_800_000_000);
        vault = new AvanaGasVault(makeAddr("treasury"), timelock, makeAddr("guardian"), 8);
        vm.deal(address(vault), 100 ether);
        for (uint256 i; i < 8; ++i) {
            signerList[i] = makeAddr(string.concat("signer", vm.toString(i)));
            vm.prank(timelock);
            vault.addSigner(signerList[i], 0.3 ether, 1 ether, 1 ether);
        }
    }

    function _fundAll(
        uint256 balance
    ) internal {
        for (uint256 i; i < 8; ++i) {
            vm.deal(signerList[i], balance);
        }
    }

    // TEST-336 verifies: REQ-GASV-004
    function test_TEST_336_topUpSingle() public {
        _fundAll(1 ether);
        vm.deal(signerList[0], 1);
        uint256 used = _txGas(keeper, address(vault), abi.encodeCall(IAvanaGasVault.topUp, (signerList[0])));
        assertEq(signerList[0].balance, 1 ether);
        vm.snapshotValue("AvanaGasVault", "topUp_single", used);
        emit log_named_uint("topUp (one due signer)", used);
    }

    // TEST-336 verifies: REQ-GASV-006
    /// @notice The budget case: 8 due signers whose four send slots have all been used before (each new send overwrites
    /// an expired entry), which is every top-up after a signer's first four.
    function test_TEST_336_topUpAllEightSignersUnderBudget() public {
        for (uint256 round; round < 4; ++round) {
            _fundAll(1);
            vault.topUpAll();
            vm.warp(block.timestamp + 1 days + 1);
        }
        _fundAll(1);
        uint256 used = _txGas(keeper, address(vault), abi.encodeCall(IAvanaGasVault.topUpAll, ()));
        for (uint256 i; i < 8; ++i) {
            assertEq(signerList[i].balance, 1 ether);
        }
        vm.snapshotValue("AvanaGasVault", "topUpAll_8due", used);
        emit log_named_uint("topUpAll (8 due signers, used slots)", used);
        assertLt(used, TOP_UP_ALL_BUDGET, "topUpAll with 8 signers");
    }

    // TEST-336 verifies: REQ-GASV-006
    /// @notice 8 due signers on their first send: each send writes a zero storage slot (20,000 gas more per signer).
    /// A signer pays this on its first and third sends only, so it is outside the steady-state budget.
    function test_TEST_336_topUpAllEightSignersFirstSends() public {
        _fundAll(1);
        uint256 used = _txGas(keeper, address(vault), abi.encodeCall(IAvanaGasVault.topUpAll, ()));
        for (uint256 i; i < 8; ++i) {
            assertEq(signerList[i].balance, 1 ether);
        }
        vm.snapshotValue("AvanaGasVault", "topUpAll_8dueFirstSends", used);
        emit log_named_uint("topUpAll (8 due signers, first sends)", used);
        assertLt(used, TX_GAS_CAP / 10, "topUpAll with 8 first sends");
    }

    // TEST-336 verifies: REQ-GASV-006
    function test_TEST_336_topUpAllNoneDue() public {
        _fundAll(1 ether);
        uint256 used = _txGas(keeper, address(vault), abi.encodeCall(IAvanaGasVault.topUpAll, ()));
        vm.snapshotValue("AvanaGasVault", "topUpAll_8funded", used);
        emit log_named_uint("topUpAll (8 funded signers)", used);
    }

    // TEST-336 verifies: REQ-GASV-006
    function test_TEST_336_topUpAllEightEmptyAccounts() public {
        uint256 used = _txGas(keeper, address(vault), abi.encodeCall(IAvanaGasVault.topUpAll, ()));
        vm.snapshotValue("AvanaGasVault", "topUpAll_8emptyAccounts", used);
        emit log_named_uint("topUpAll (8 due signers, empty accounts)", used);
        assertLt(used, TX_GAS_CAP / 10, "topUpAll with 8 empty accounts");
    }
}
