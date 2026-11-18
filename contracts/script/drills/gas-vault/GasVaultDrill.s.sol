// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../../src/governance/roles/AvanaRoles.sol";
import {IAvanaGasVault} from "../../../src/periphery/gas-vault/IAvanaGasVault.sol";
import {AvanaAccess} from "../../deploy/lib/AvanaAccess.sol";
import {DeployBase} from "../../deploy/lib/DeployBase.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {console2} from "forge-std/console2.sol";

/// @title GasVaultDrill
/// @notice The AvanaGasVault testnet drill (docs/keeper-gas.md, Testnet drills): one action per run, each signed by the
/// role that makes that call on a real deployment. Run through `drill.sh`, which picks the role's encrypted Foundry
/// keystore; without `--broadcast` forge only simulates.
/// @dev Roles, from the environment (addresses only; no key is ever read): `DRILL_TREASURY` (stands for the
/// `feeRecipient` treasury Safe), `DRILL_TIMELOCK` (an account standing for the governance Safe: it holds the governance role of a
/// drill-only AccessManager with no execution delay, so `addSigner` runs without the 4-day delay; the delay itself is
/// rehearsed on anvil by the `12-*` deploy steps), `DRILL_GUARDIAN` (the
/// Emergency Guardian Safe), `DRILL_SIGNER` (the keeper signer refilled) and the deployer, who also calls the
/// permissionless top-ups. Amounts are small and set by `DRILL_MIN_WEI`, `DRILL_TARGET_WEI`, `DRILL_CAP_WEI` and
/// `DRILL_FUND_WEI`. The vault's address is written to `deployments-local/<network>/gas-vault-drill.json`.
/// The 24 h cap is hit by spending the signer down twice: the first top-up sends `target − balance`, the second is cut
/// to what is left of the cap (`ToppedUp.amount < requested`, the event M-36 pages on), and a third is quoted at 0.
contract GasVaultDrill is DeployBase {
    uint256 internal constant GAS_RESERVE = 0.0005 ether;

    function _role(
        string memory name
    ) internal view returns (address) {
        return vm.envAddress(name);
    }

    function _min() internal view returns (uint256) {
        return vm.envOr("DRILL_MIN_WEI", uint256(0.002 ether));
    }

    function _target() internal view returns (uint256) {
        return vm.envOr("DRILL_TARGET_WEI", uint256(0.005 ether));
    }

    function _cap() internal view returns (uint256) {
        return vm.envOr("DRILL_CAP_WEI", uint256(0.006 ether));
    }

    function _vault() internal view returns (IAvanaGasVault) {
        string memory path = _outputPath("gas-vault-drill");
        require(vm.exists(path), "no drill vault: run the deploy action first");
        return IAvanaGasVault(payable(vm.parseJsonAddress(vm.readFile(path), ".AvanaGasVault")));
    }

    /// @notice Deployer: a drill AccessManager, the vault with the drill's treasury, that manager and guardian, and the
    /// vault's governed functions mapped to the governance role, held by the stand-in. The deployer gives up its admin role.
    function deploy() external {
        address treasury = _role("DRILL_TREASURY");
        address governance = _role("DRILL_TIMELOCK");
        address guardian = _role("DRILL_GUARDIAN");
        string memory path = _outputPath("gas-vault-drill");
        if (vm.exists(path)) {
            address earlier = vm.parseJsonAddress(vm.readFile(path), ".AvanaGasVault");
            require(
                earlier.code.length == 0,
                "a drill vault is deployed already: remove gas-vault-drill.json to deploy another"
            );
        }
        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        AccessManager manager = new AccessManager(sender);
        address vault = _deploy(
            "AvanaGasVault",
            bytes.concat(
                _artifact("AvanaGasVault.sol", "AvanaGasVault"),
                abi.encode(treasury, address(manager), guardian, uint256(8))
            )
        );
        manager.labelRole(AvanaRoles.GOVERNANCE_ROLE, AvanaRoles.GOVERNANCE_LABEL);
        manager.setTargetFunctionRole(
            vault,
            AvanaAccess.selectorsOf(AvanaAccess.Kind.GasVault, AvanaRoles.GOVERNANCE_ROLE),
            AvanaRoles.GOVERNANCE_ROLE
        );
        manager.grantRole(AvanaRoles.GOVERNANCE_ROLE, governance, 0);
        manager.grantRole(AvanaRoles.ADMIN_ROLE, governance, 0);
        manager.renounceRole(AvanaRoles.ADMIN_ROLE, sender);
        vm.stopBroadcast();
        vm.createDir(string.concat(vm.projectRoot(), "/", OUTPUT_DIR, "/", _network()), true);
        vm.writeJson(vm.serializeAddress("drill", "AvanaGasVault", vault), path);
        IAvanaGasVault v = IAvanaGasVault(payable(vault));
        require(
            v.TREASURY() == treasury && IAccessManaged(vault).authority() == address(manager)
                && v.GUARDIAN() == guardian,
            "immutables"
        );
        console2.log("drill vault", vault);
    }

    /// @notice Treasury: a lump sum into the vault.
    function fund() external {
        IAvanaGasVault v = _vault();
        uint256 amount = vm.envOr("DRILL_FUND_WEI", uint256(0.02 ether));
        uint256 before = address(v).balance;
        vm.broadcast();
        v.fund{value: amount}();
        require(address(v).balance == before + amount, "vault not funded");
        console2.log("vault holds", address(v).balance);
    }

    /// @notice Governance stand-in: lists the signer with the drill's values.
    function addSigner() external {
        IAvanaGasVault v = _vault();
        address signer = _role("DRILL_SIGNER");
        vm.broadcast();
        v.addSigner(signer, _min(), _target(), _cap());
        require(v.isSigner(signer), "signer not listed");
        console2.log("signer listed", signer);
    }

    /// @notice Anyone: tops the signer up to its target. The signer must be below its minimum.
    function topUp() external {
        IAvanaGasVault v = _vault();
        address signer = _role("DRILL_SIGNER");
        (uint256 amount, uint256 requested) = v.quoteTopUp(signer);
        require(amount > 0, "nothing to send: the signer is not below its minimum, or the cap is used up");
        uint256 before = signer.balance;
        vm.broadcast();
        v.topUp(signer);
        require(signer.balance == before + amount, "signer not paid the quoted amount");
        console2.log("topped up", amount);
        console2.log("  requested", requested);
        if (amount < requested) console2.log("  capped: M-36 pages on this ToppedUp");
    }

    /// @notice Signer: spends its balance down to the gas reserve by sending it to the treasury.
    function drain() external {
        address signer = _role("DRILL_SIGNER");
        address treasury = _role("DRILL_TREASURY");
        require(signer.balance > GAS_RESERVE, "signer already drained");
        uint256 amount = signer.balance - GAS_RESERVE;
        vm.broadcast();
        (bool ok,) = treasury.call{value: amount}("");
        require(ok, "transfer to treasury failed");
        console2.log("signer drained, sent to treasury", amount);
    }

    /// @notice Read only: after the second top-up the 24 h cap is used up, so a third is quoted at 0.
    function checkCap() external view {
        IAvanaGasVault v = _vault();
        address signer = _role("DRILL_SIGNER");
        uint256 sent = v.sentInPeriod(signer);
        (uint256 amount,) = v.quoteTopUp(signer);
        console2.log("sent in the last 24 h", sent);
        console2.log("quote now", amount);
        require(sent == _cap() && amount == 0, "the 24 h cap is not used up");
    }

    /// @notice Guardian: pauses top-ups; every top-up is then quoted at 0.
    function pause() external {
        IAvanaGasVault v = _vault();
        vm.broadcast();
        v.pause();
        (uint256 amount,) = v.quoteTopUp(_role("DRILL_SIGNER"));
        require(v.paused() && amount == 0, "not paused");
        console2.log("paused");
    }

    /// @notice Governance stand-in: lifts the pause.
    function unpause() external {
        IAvanaGasVault v = _vault();
        vm.broadcast();
        v.unpause();
        require(!v.paused(), "still paused");
        console2.log("unpaused");
    }

    /// @notice Guardian: removes the signer at once.
    function removeSigner() external {
        IAvanaGasVault v = _vault();
        address signer = _role("DRILL_SIGNER");
        vm.broadcast();
        v.removeSigner(signer);
        require(!v.isSigner(signer), "signer still listed");
        console2.log("signer removed", signer);
    }

    /// @notice Governance stand-in: withdraws everything; it can only go to the treasury.
    function withdraw() external {
        IAvanaGasVault v = _vault();
        address treasury = v.TREASURY();
        uint256 amount = address(v).balance;
        uint256 before = treasury.balance;
        vm.broadcast();
        v.withdraw(amount);
        require(address(v).balance == 0 && treasury.balance == before + amount, "withdrawal did not reach the treasury");
        console2.log("withdrawn to treasury", amount);
    }
}
