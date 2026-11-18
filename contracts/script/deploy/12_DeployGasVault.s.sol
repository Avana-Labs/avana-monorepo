// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAvanaGasVault} from "../../src/periphery/gas-vault/IAvanaGasVault.sol";
import {IParameterStore} from "../../src/policy/parameter-store/IParameterStore.sol";
import {DeployBase} from "./lib/DeployBase.sol";
import {ITimelockOps, TimelockOperations} from "./lib/TimelockOperations.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployGasVault
/// @notice The chain's AvanaGasVault (2.24 `REQ-GASV-001`…): one immutable vault per chain that refills Avana's own
/// keeper signers. It runs any time after `03-avana` and `05-execute-access-operations`, and before the first
/// `activateMarket` that needs keeper gas. `AVANA_GAS_VAULT_STEP`:
/// - `deploy`: `AvanaGasVault(treasury, timelock, guardian, maxSigners)` with `treasury` = the config's `feeRecipient`,
///   `timelock` = the AvanaTimelock of `avana.json` and `guardian` = the Emergency Guardian Safe. Before it deploys, the
///   step checks that the treasury is the ParameterStore's `feeRecipient` on chain and is no operator helper's
///   `fundingSafe`. No role is granted: the vault has none. Writes `gas-vault.json`.
/// - `signers`: the timelock operation `gas-vault-signers`, one `addSigner` per configured signer not yet listed, at the
///   normal delay; written for the governance Safe and, with `AVANA_SCHEDULE`, scheduled as the Safe (anvil). With every
///   signer listed, nothing is written.
/// - `fund`: the treasury sends the vault up to `gasVault.fundWei` (a lump sum: 30 days of the measured daily spend plus
///   the burst reserve). On anvil and the test networks the funder broadcasts: the treasury, or `AVANA_GAS_VAULT_FUNDER`
///   when set (a test network's treasury is an address that signs nothing, so its deployer funds the vault; `fund` is
///   open to any sender). On Ethereum and Base the step only prints the treasury Safe's transaction, which its signers
///   execute.
/// @dev Config, `gasVault`: `maxSigners` (≤ 8), `fundWei`, and `signers[]` of `{signer, minBalanceWei,
/// targetBalanceWei, periodCapWei}`, the primary and standby keeper signers of the chain. The values come from the
/// measured daily spend `D` (`minBalance = 3 × D`, `targetBalance = periodCap = 7 × D + B`).
contract DeployGasVault is TimelockOperations, DeployBase {
    string internal cfg;

    function run() external {
        runStep(vm.envString("AVANA_GAS_VAULT_STEP"));
    }

    /// @notice Runs one step by name (`run` reads it from `AVANA_GAS_VAULT_STEP`).
    function runStep(
        string memory step
    ) public {
        cfg = vm.readFile(_configPath(_network()));
        require(vm.parseJsonUint(cfg, ".chainId") == block.chainid, "config is for another chain");
        if (_eq(step, "deploy")) _deployVault();
        else if (_eq(step, "signers")) _scheduleSigners();
        else if (_eq(step, "fund")) _fund();
        else revert(string.concat("unknown AVANA_GAS_VAULT_STEP ", step));
    }

    /// @notice The vault's three addresses, checked against the chain: the treasury is the ParameterStore's
    /// `feeRecipient`, differs from every operator helper's `fundingSafe`, the timelock and the guardian.
    function _addresses() internal view returns (address treasury, address timelock, address guardian) {
        string memory avana = vm.readFile(_outputPath("avana"));
        treasury = _addr(cfg, ".parameters.globals.feeRecipient");
        timelock = vm.parseJsonAddress(avana, ".timelock");
        guardian = _addr(cfg, ".governance.emergencyGuardian");
        address store = vm.parseJsonAddress(avana, ".parameterStore.proxy");
        address onChain = IParameterStore(store).feeRecipient();
        require(
            treasury == onChain,
            string.concat(
                "gas vault treasury ",
                vm.toString(treasury),
                " is not the ParameterStore's feeRecipient ",
                vm.toString(onChain)
            )
        );
        uint256 n = _count(cfg, ".operatorHelpers");
        for (uint256 i = 0; i < n; ++i) {
            address safe = _addr(cfg, string.concat(".operatorHelpers[", vm.toString(i), "].fundingSafe"));
            require(treasury != safe, "gas vault treasury is an operator helper's FUNDING_SAFE");
        }
        require(treasury != timelock && treasury != guardian, "gas vault treasury is the timelock or the guardian");
    }

    /// @notice The vault an earlier `deploy` recorded, or 0.
    function _vault() internal view returns (address) {
        return _recorded("gas-vault", ".AvanaGasVault");
    }

    function _deployVault() internal {
        // Off anvil, HEAD must be the release tag with the deployed sources unchanged, as for every other step.
        _requireReleaseCheckout(vm.envOr("AVANA_RELEASE", vm.parseJsonString(cfg, ".release")));
        (address treasury, address timelock, address guardian) = _addresses();
        uint256 maxSigners = vm.parseJsonUint(cfg, ".gasVault.maxSigners");
        address done = _vault();
        if (done != address(0)) {
            IAvanaGasVault v = IAvanaGasVault(payable(done));
            require(
                v.TREASURY() == treasury && v.TIMELOCK() == timelock && v.GUARDIAN() == guardian
                    && v.MAX_SIGNERS() == maxSigners,
                "the recorded AvanaGasVault has other immutables than the config: deploy a new one by hand"
            );
            console2.log("AvanaGasVault", done, "(deployed earlier)");
            return;
        }
        vm.startBroadcast();
        address vault = _deploy(
            "AvanaGasVault",
            bytes.concat(
                _artifact("AvanaGasVault.sol", "AvanaGasVault"), abi.encode(treasury, timelock, guardian, maxSigners)
            )
        );
        vm.stopBroadcast();
        vm.writeJson(vm.serializeAddress("gas-vault", "AvanaGasVault", vault), _outputPath("gas-vault"));
        console2.log("AvanaGasVault", vault);
        console2.log("  treasury", treasury);
        console2.log("  timelock", timelock);
        console2.log("  guardian", guardian);
    }

    /// @notice One `addSigner` per configured signer the vault does not list yet. A listed signer whose values differ
    /// from the config is reported, not changed: raising goes through `setSignerConfig` (normal delay) and lowering
    /// through the guardian's `tightenSigner`, each its own decision.
    function _scheduleSigners() internal {
        address vault = _vault();
        require(vault != address(0), "no AvanaGasVault recorded: run 12-gas-vault first");
        IAvanaGasVault v = IAvanaGasVault(payable(vault));
        address timelock = v.TIMELOCK();
        uint256 n = _count(cfg, ".gasVault.signers");
        Operation memory op = _newOperation("gas-vault-signers", vm.parseJsonString(cfg, ".release"), n);
        for (uint256 i = 0; i < n; ++i) {
            string memory k = string.concat(".gasVault.signers[", vm.toString(i), "]");
            address signer = _addr(cfg, string.concat(k, ".signer"));
            uint256 minBalance = vm.parseJsonUint(cfg, string.concat(k, ".minBalanceWei"));
            uint256 targetBalance = vm.parseJsonUint(cfg, string.concat(k, ".targetBalanceWei"));
            uint256 periodCap = vm.parseJsonUint(cfg, string.concat(k, ".periodCapWei"));
            if (v.isSigner(signer)) {
                IAvanaGasVault.SignerConfig memory s = v.signerConfig(signer);
                if (s.minBalance != minBalance || s.targetBalance != targetBalance || s.periodCap != periodCap) {
                    console2.log("listed with other values, not changed:", signer);
                } else {
                    console2.log("listed already:", signer);
                }
                continue;
            }
            _add(
                op,
                vault,
                abi.encodeCall(IAvanaGasVault.addSigner, (signer, minBalance, targetBalance, periodCap)),
                string.concat("AvanaGasVault.addSigner ", vm.toString(signer))
            );
        }
        if (op.targets.length == 0) {
            console2.log("gas-vault-signers nothing to schedule: every configured signer is listed");
            return;
        }
        _freshSalt(timelock, op);
        bytes32 id = _writeOperation(timelock, op);
        console2.log("gas-vault-signers", vm.toString(id), _operationPath(op.name));
        if (vm.envOr("AVANA_SCHEDULE", false)) {
            address safe = _addr(cfg, ".governance.governanceSafe");
            uint256 delay = ITimelockOps(timelock).requiredDelay(op.targets, op.payloads);
            vm.broadcast(safe);
            ITimelockOps(timelock).scheduleBatch(op.targets, op.values, op.payloads, bytes32(0), op.salt, delay);
            console2.log("scheduled as the governance Safe", safe);
        }
    }

    /// @notice Brings the vault's balance up to `gasVault.fundWei` from the treasury.
    function _fund() internal {
        address vault = _vault();
        require(vault != address(0), "no AvanaGasVault recorded: run 12-gas-vault first");
        uint256 goal = vm.parseJsonUint(cfg, ".gasVault.fundWei");
        uint256 held = vault.balance;
        if (held >= goal) {
            console2.log("gas vault holds", held, "nothing to fund");
            return;
        }
        uint256 amount = goal - held;
        address treasury = IAvanaGasVault(payable(vault)).TREASURY();
        if (block.chainid == 1 || block.chainid == 8453) {
            console2.log("treasury Safe transaction (not sent):", treasury);
            console2.log("  to", vault);
            console2.log("  value", amount);
            console2.log("  data", vm.toString(abi.encodeCall(IAvanaGasVault.fund, ())));
            return;
        }
        vm.broadcast(vm.envOr("AVANA_GAS_VAULT_FUNDER", treasury));
        IAvanaGasVault(payable(vault)).fund{value: amount}();
        console2.log("  funded gas vault", vault, amount);
    }
}
