// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {AvanaCreate3Factory} from "./AvanaCreate3Factory.sol";
import {IAccessManagerOps} from "./lib/AccessOperations.sol";
import {AvanaAccess} from "./lib/AvanaAccess.sol";
import {DeployBase} from "./lib/DeployBase.sol";
import {AvanaDeployment, ChainInputs, CoreStack, IntegrationInput} from "./lib/DeployTypes.sol";
import {DeploymentOutput} from "./lib/DeploymentOutput.sol";
import {console2} from "forge-std/console2.sol";

/// @notice The AccessManager admin calls 03 makes beyond `IAccessManagerOps`.
interface IAccessManagerAdmin {
    function renounceRole(
        uint64 roleId,
        address callerConfirmation
    ) external;
}

/// @title DeployAvana
/// @notice Step 3: Avana's AccessManager and, for every integration of the config, its core stack: the LPVault, the
/// RiskModule, the LiquidationModule, the AaveAdapter and, with an Aave V3 Pool, FlashloanRepay and one operator
/// FlashLiquidator per `operatorHelpers` entry. Then every role of the manager, and the admin handed to the DAO (the
/// Aave governance executor, guardian of every role). Writes `deployments-local/<network>/avana.json`.
/// @dev Every contract is CREATE3-deployed in the deployer's namespace (`_deploy3`), so its address depends only on the
/// deployer, the release and its name. The RiskModule is built with the LiquidationModule's predicted address: the
/// module's constructor checks that the RiskModule names it.
/// Roles, set while the deployer is the manager's initial admin:
/// - core roles, one set per integration with no delay (`AvanaAccess.coreRole`): the RiskModule on
///   `LPVault.listMarket`, the AaveAdapter on the LPVault's user flows, the LiquidationModule on `LPVault.unwind`, and
///   the burn role (vault-token `burn`, mapped per token in `09_ListMarkets`) held by both;
/// - the RiskModule's setters: the governance role (the Safe, 4 to 5 days) and the tighten role (the Safe, 12 hours;
///   the risk steward, the Joint Configuration Safe, with no delay);
/// - the admin role to the DAO (`governance.aaveGovernanceExecutor`), then renounced by the deployer.
/// A rerun keeps every contract already at its address and skips the roles once the deployer is no longer admin.
/// Run: `script/deploy/step.sh 03-avana`.
contract DeployAvana is DeployBase, DeploymentOutput {
    string internal constant FLASH_LIQUIDATOR_ARTIFACT = "../packages/liquidator/out/FlashLiquidator.sol/FlashLiquidator.json";

    function run() external {
        ChainInputs memory c = _loadInputs(_network());
        deployer = vm.envOr("AVANA_DEPLOYER", msg.sender);
        release = c.release;
        create3 = AvanaCreate3Factory(_create3FactoryAddress());
        require(address(create3).code.length != 0, "AvanaCreate3Factory missing: run 00-factories first");
        string memory record = _releaseRecordPath();
        if (bytes(record).length != 0) _checkReleaseRecord(record, "");

        AvanaDeployment memory d;
        d.factory = address(create3);
        d.deployer = deployer;
        d.stacks = new CoreStack[](c.integrations.length);

        vm.startBroadcast(deployer);
        d.accessManager =
            _deployOnce("AccessManager", _artifact("AccessManager.sol", "AccessManager"), abi.encode(deployer));
        for (uint256 i = 0; i < c.integrations.length; ++i) {
            d.stacks[i] = _deployStack(c, c.integrations[i], d.accessManager);
        }
        (bool admin,) = IAccessManagerOps(d.accessManager).hasRole(AvanaRoles.ADMIN_ROLE, deployer);
        if (admin) {
            _configureRoles(c, IAccessManagerOps(d.accessManager), d.stacks);
        } else {
            console2.log("roles: the deployer is no longer the manager's admin; nothing changed");
        }
        vm.stopBroadcast();

        _writeAvanaOutput(_outputPath("avana"), c, d);
        console2.log("AccessManager", d.accessManager);
        console2.log("output", _outputPath("avana"));
    }

    // ─── Contracts ───

    function _deployStack(
        ChainInputs memory c,
        IntegrationInput memory integ,
        address manager
    ) private returns (CoreStack memory s) {
        s.integrationId = integ.integrationId;
        s.kind = integ.kind;
        string memory p = string.concat("I", vm.toString(integ.integrationId), ".");
        s.lpVault = _deployOnce(string.concat(p, "LPVault"), _lpVaultCode(integ), _lpVaultArgs(integ, manager));
        address predictedModule = _predict(string.concat(p, "LiquidationModule"));
        s.riskModule = _deployOnce(
            string.concat(p, "RiskModule"),
            _artifact("RiskModule.sol", "RiskModule"),
            abi.encode(manager, s.lpVault, predictedModule)
        );
        s.liquidationModule = _deployOnce(
            string.concat(p, "LiquidationModule"),
            _artifact("LiquidationModule.sol", "LiquidationModule"),
            abi.encode(s.riskModule)
        );
        require(s.liquidationModule == predictedModule, "LiquidationModule off its prediction");
        s.aaveAdapter = _deployOnce(
            string.concat(p, "AaveAdapter"), _artifact("AaveAdapter.sol", "AaveAdapter"), abi.encode(s.riskModule)
        );
        s.flashLiquidators = new address[](c.v3Pool == address(0) ? 0 : c.operatorHelpers.length);
        if (c.v3Pool == address(0)) return s;
        s.flashloanRepay = _deployOnce(
            string.concat(p, "FlashloanRepay"),
            _artifact("FlashloanRepay.sol", "FlashloanRepay"),
            abi.encode(s.aaveAdapter, c.v3Pool)
        );
        if (c.operatorHelpers.length == 0) return s;
        string memory path = string.concat(vm.projectRoot(), "/", FLASH_LIQUIDATOR_ARTIFACT);
        require(vm.exists(path), "no FlashLiquidator artifact: build packages/liquidator/ first (forge build in packages/liquidator/)");
        for (uint256 h = 0; h < c.operatorHelpers.length; ++h) {
            s.flashLiquidators[h] = _deployOnce(
                string.concat(p, "FlashLiquidator.", vm.toString(h)),
                vm.getCode(path),
                abi.encode(c.v3Pool, s.liquidationModule, c.operatorHelpers[h].signer)
            );
        }
    }

    function _lpVaultCode(
        IntegrationInput memory integ
    ) private view returns (bytes memory) {
        if (_eq(integ.kind, "uniswap-v3")) return _artifact("UniswapV3Integration.sol", "UniswapV3Integration");
        if (_eq(integ.kind, "slipstream")) return _artifact("SlipstreamIntegration.sol", "SlipstreamIntegration");
        if (_eq(integ.kind, "uniswap-v4")) return _artifact("UniswapV4Integration.sol", "UniswapV4Integration");
        revert(string.concat("unknown integration kind ", integ.kind));
    }

    function _lpVaultArgs(
        IntegrationInput memory integ,
        address manager
    ) private pure returns (bytes memory) {
        if (_eq(integ.kind, "uniswap-v3")) {
            require(
                integ.positionManagers.length == 1 && integ.factories.length == 1, "uniswap-v3: one NFPM, one factory"
            );
            return abi.encode(manager, integ.positionManagers[0], integ.factories[0]);
        }
        if (_eq(integ.kind, "slipstream")) {
            require(
                integ.positionManagers.length == 4 && integ.factories.length == 4,
                "slipstream: four position managers and four factories"
            );
            address[4] memory npms;
            address[4] memory factories;
            for (uint256 g = 0; g < 4; ++g) {
                (npms[g], factories[g]) = (integ.positionManagers[g], integ.factories[g]);
            }
            return abi.encode(manager, npms, factories);
        }
        require(integ.positionManagers.length == 1, "uniswap-v4: one PositionManager");
        return abi.encode(manager, integ.positionManagers[0]);
    }

    /// @notice The contract at `name`'s address, deployed now unless an earlier run did.
    function _deployOnce(
        string memory name,
        bytes memory code,
        bytes memory args
    ) private returns (address a) {
        a = _predict(name);
        if (a.code.length != 0) {
            console2.log(string.concat(name, ": kept"), a);
            return a;
        }
        a = _deploy3(name, bytes.concat(code, args));
        console2.log(name, a);
    }

    // ─── Roles ───

    function _configureRoles(
        ChainInputs memory c,
        IAccessManagerOps m,
        CoreStack[] memory stacks
    ) private {
        uint64[] memory ids = AvanaAccess.roles();
        for (uint256 i = 0; i < ids.length; ++i) {
            m.labelRole(ids[i], AvanaAccess.roleLabel(ids[i]));
        }
        for (uint256 i = 0; i < stacks.length; ++i) {
            _stackRoles(m, stacks[i]);
        }
        address safe = c.gov.governanceSafe;
        uint32 governanceDelay = AvanaAccess.governanceDelay(c.params.timelockNormalDelay);
        m.grantRole(AvanaRoles.GOVERNANCE_ROLE, safe, governanceDelay);
        m.grantRole(AvanaRoles.TIGHTEN_ROLE, safe, AvanaAccess.TIGHTEN_DELAY);
        if (c.gov.jointConfigSafe != address(0) && c.gov.jointConfigSafe != safe) {
            m.grantRole(AvanaRoles.TIGHTEN_ROLE, c.gov.jointConfigSafe, 0);
        }
        address dao = c.gov.aaveGovernanceExecutor;
        require(dao != address(0) && dao != deployer, "governance.aaveGovernanceExecutor: the manager's admin");
        m.grantRole(AvanaRoles.ADMIN_ROLE, dao, 0);
        IAccessManagerAdmin(address(m)).renounceRole(AvanaRoles.ADMIN_ROLE, deployer);
        console2.log("roles set; admin handed to the DAO (Aave governance executor)", dao);
    }

    function _stackRoles(
        IAccessManagerOps m,
        CoreStack memory s
    ) private {
        uint32 id = s.integrationId;
        uint64 risk = AvanaAccess.coreRole(id, AvanaAccess.CORE_RISK_MODULE);
        uint64 adapter = AvanaAccess.coreRole(id, AvanaAccess.CORE_ADAPTER);
        uint64 liquidation = AvanaAccess.coreRole(id, AvanaAccess.CORE_LIQUIDATION);
        uint64 burn = AvanaAccess.coreRole(id, AvanaAccess.CORE_BURN);
        m.labelRole(risk, AvanaAccess.coreRoleLabel(id, AvanaAccess.CORE_RISK_MODULE));
        m.labelRole(adapter, AvanaAccess.coreRoleLabel(id, AvanaAccess.CORE_ADAPTER));
        m.labelRole(liquidation, AvanaAccess.coreRoleLabel(id, AvanaAccess.CORE_LIQUIDATION));
        m.labelRole(burn, AvanaAccess.coreRoleLabel(id, AvanaAccess.CORE_BURN));
        m.setTargetFunctionRole(s.lpVault, AvanaAccess.lpVaultRiskSelectors(), risk);
        m.setTargetFunctionRole(s.lpVault, AvanaAccess.lpVaultAdapterSelectors(), adapter);
        m.setTargetFunctionRole(s.lpVault, AvanaAccess.lpVaultLiquidationSelectors(), liquidation);
        m.setTargetFunctionRole(s.riskModule, AvanaAccess.riskModuleGovernanceSelectors(), AvanaRoles.GOVERNANCE_ROLE);
        m.setTargetFunctionRole(s.riskModule, AvanaAccess.riskModuleTightenSelectors(), AvanaRoles.TIGHTEN_ROLE);
        m.grantRole(risk, s.riskModule, 0);
        m.grantRole(adapter, s.aaveAdapter, 0);
        m.grantRole(liquidation, s.liquidationModule, 0);
        m.grantRole(burn, s.aaveAdapter, 0);
        m.grantRole(burn, s.liquidationModule, 0);
    }
}
