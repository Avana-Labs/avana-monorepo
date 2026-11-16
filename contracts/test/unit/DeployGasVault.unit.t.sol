// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ExecuteOperations} from "../../script/deploy/05_ExecuteOperations.s.sol";
import {DeployGasVault} from "../../script/deploy/12_DeployGasVault.s.sol";
import {AvanaTimelock} from "../../src/governance/timelock/AvanaTimelock.sol";
import {GovernedTargets} from "../../src/governance/timelock/types/GovernedTargets.sol";
import {SelectorPair} from "../../src/governance/timelock/types/SelectorPair.sol";
import {IAvanaGasVault} from "../../src/periphery/gas-vault/IAvanaGasVault.sol";
import {IParameterStoreViews} from "../../src/policy/parameter-store/IParameterStoreViews.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The gas vault's deploy steps (`script/deploy/12_DeployGasVault.s.sol`) as `step.sh` runs them, against a
/// real AvanaTimelock and the deploy outputs of an earlier `03-avana`: the treasury checks refuse a wrong address,
/// `deploy` writes `gas-vault.json`, `signers` writes and schedules the timelock operation, `05` executes it after the
/// normal delay, a second `signers` has nothing to schedule, `fund` brings the vault to `fundWei`, and a drained signer
/// is refilled by anyone's `topUpAll`. One test function: the steps share the files of one test network.
contract DeployGasVaultTest is Test {
    string internal constant NETWORK = "gas-vault-unit";
    string internal constant DIR = "deployments-local/gas-vault-unit";
    uint256 internal constant NORMAL_DELAY = 432_000;

    address internal safe = makeAddr("governanceSafe");
    address internal guardian = makeAddr("emergencyGuardian");
    address internal aaveExecutor = makeAddr("aaveGovernanceExecutor");
    address internal treasury = makeAddr("feeRecipient");
    address internal fundingSafe = makeAddr("fundingSafe");
    address internal primary = makeAddr("keeperPrimary");
    address internal standby = makeAddr("keeperStandby");
    address internal store = makeAddr("parameterStore");
    AvanaTimelock internal timelock;

    function setUp() public {
        address[] memory proposers = new address[](2);
        (proposers[0], proposers[1]) = (safe, aaveExecutor);
        address[] memory executors = new address[](1);
        executors[0] = safe;
        address[] memory cancellers = new address[](1);
        cancellers[0] = guardian;
        address[] memory dao = new address[](1);
        dao[0] = aaveExecutor;
        SelectorPair[] memory none = new SelectorPair[](0);
        timelock = new AvanaTimelock(
            proposers,
            executors,
            cancellers,
            dao,
            NORMAL_DELAY,
            true,
            none,
            none,
            GovernedTargets(store, makeAddr("marketRegistry"), makeAddr("lpVaultSwap"))
        );
        vm.etch(store, hex"00");
        vm.mockCall(store, abi.encodeCall(IParameterStoreViews.feeRecipient, ()), abi.encode(treasury));
        vm.createDir(DIR, true);
        vm.writeFile(
            string.concat(DIR, "/avana.json"),
            string.concat(
                '{"timelock":"',
                vm.toString(address(timelock)),
                '","parameterStore":{"proxy":"',
                vm.toString(store),
                '"}}'
            )
        );
        if (vm.exists(string.concat(DIR, "/gas-vault.json"))) vm.removeFile(string.concat(DIR, "/gas-vault.json"));
        vm.setEnv("AVANA_NETWORK", NETWORK);
        vm.setEnv("AVANA_CONFIG", string.concat(DIR, "/config.json"));
        vm.setEnv("AVANA_SCHEDULE", "true");
        vm.setEnv("AVANA_OPERATIONS", "gas-vault-signers");
        vm.deal(treasury, 1000 ether);
    }

    function _config(
        address feeRecipient,
        address helperSafe
    ) internal {
        string memory signer = '","minBalanceWei":"3000000000000000000","targetBalanceWei":"10000000000000000000",'
            '"periodCapWei":"10000000000000000000"}';
        vm.writeFile(
            string.concat(DIR, "/config.json"),
            string.concat(
                '{"chainId":',
                vm.toString(block.chainid),
                ',"release":"v0.1.0-local","governance":{"governanceSafe":"',
                vm.toString(safe),
                '","emergencyGuardian":"',
                vm.toString(guardian),
                '"},"parameters":{"globals":{"feeRecipient":"',
                vm.toString(feeRecipient),
                '"}},"operatorHelpers":[{"signer":"',
                vm.toString(primary),
                '","fundingSafe":"',
                vm.toString(helperSafe),
                '","maxTopUpBps":100}],"gasVault":{"maxSigners":8,"fundWei":"100000000000000000000","signers":[{"signer":"',
                vm.toString(primary),
                signer,
                ',{"signer":"',
                vm.toString(standby),
                signer,
                "]}}"
            )
        );
    }

    // TEST-339 verifies: REQ-GASV-002, REQ-GASV-007, REQ-GASV-006
    function test_TEST_339_deploySignersFundAndTopUp() public {
        DeployGasVault script = new DeployGasVault();

        // The treasury must be the ParameterStore's feeRecipient and no operator helper's FUNDING_SAFE.
        _config(makeAddr("otherTreasury"), fundingSafe);
        vm.expectRevert();
        script.runStep("deploy");
        vm.mockCall(store, abi.encodeCall(IParameterStoreViews.feeRecipient, ()), abi.encode(fundingSafe));
        _config(fundingSafe, fundingSafe);
        vm.expectRevert(bytes("gas vault treasury is an operator helper's FUNDING_SAFE"));
        script.runStep("deploy");
        vm.mockCall(store, abi.encodeCall(IParameterStoreViews.feeRecipient, ()), abi.encode(treasury));
        _config(treasury, fundingSafe);

        // Signers and funding need the vault first.
        vm.expectRevert(bytes("no AvanaGasVault recorded: run 12-gas-vault first"));
        script.runStep("signers");

        script.runStep("deploy");
        IAvanaGasVault vault = IAvanaGasVault(
            payable(vm.parseJsonAddress(vm.readFile(string.concat(DIR, "/gas-vault.json")), ".AvanaGasVault"))
        );
        assertEq(vault.TREASURY(), treasury);
        assertEq(vault.TIMELOCK(), address(timelock));
        assertEq(vault.GUARDIAN(), guardian);
        assertEq(vault.MAX_SIGNERS(), 8);
        assertEq(vault.signers().length, 0, "no signer before the timelock operation");

        // A second deploy keeps the recorded vault.
        script.runStep("deploy");
        assertEq(
            vm.parseJsonAddress(vm.readFile(string.concat(DIR, "/gas-vault.json")), ".AvanaGasVault"), address(vault)
        );

        // addSigner of both signers, scheduled as the Safe at the normal delay, executed by anyone once ready.
        script.runStep("signers");
        string memory op = vm.readFile(string.concat(DIR, "/operation-gas-vault-signers.json"));
        assertEq(vm.parseJsonUint(op, ".delay"), NORMAL_DELAY);
        assertEq(vm.parseJsonAddressArray(op, ".targets").length, 2);
        ExecuteOperations exec = new ExecuteOperations();
        exec.run();
        assertFalse(vault.isSigner(primary), "not executed before the delay");
        vm.warp(block.timestamp + NORMAL_DELAY);
        exec.run();
        assertTrue(vault.isSigner(primary));
        assertTrue(vault.isSigner(standby));
        IAvanaGasVault.SignerConfig memory c = vault.signerConfig(standby);
        assertEq(c.minBalance, 3 ether);
        assertEq(c.targetBalance, 10 ether);
        assertEq(c.periodCap, 10 ether);

        // Nothing new: no operation scheduled.
        bytes32 before = keccak256(bytes(vm.readFile(string.concat(DIR, "/operation-gas-vault-signers.json"))));
        script.runStep("signers");
        assertEq(keccak256(bytes(vm.readFile(string.concat(DIR, "/operation-gas-vault-signers.json")))), before);

        // The treasury funds the lump sum; a second run sends nothing.
        script.runStep("fund");
        assertEq(address(vault).balance, 100 ether);
        script.runStep("fund");
        assertEq(address(vault).balance, 100 ether);
        assertEq(treasury.balance, 900 ether);

        // A drained signer is refilled to its target by anyone, who receives nothing.
        vm.deal(primary, 1 ether);
        vm.deal(standby, 5 ether);
        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        (uint256 count, uint256 total) = vault.topUpAll();
        assertEq(count, 1);
        assertEq(total, 9 ether);
        assertEq(primary.balance, 10 ether);
        assertEq(standby.balance, 5 ether);
        assertEq(anyone.balance, 0);
    }
}
