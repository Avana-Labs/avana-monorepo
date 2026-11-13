// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaDeployment, ChainInputs, UpgradeableDeployment} from "./DeployTypes.sol";
import {Script} from "forge-std/Script.sol";

/// @title DeploymentOutput
/// @notice Writes what `03_DeployAvana` deployed to `deployments-local/<network>/avana.json`, the input of the release
/// manifest producer (`packages/protocol`, `npm run manifest -- produce`), which adds code hashes, blocks and roles
/// read from the chain.
abstract contract DeploymentOutput is Script {
    function _writeAvanaOutput(
        string memory path,
        ChainInputs memory c,
        AvanaDeployment memory d
    ) internal {
        string memory o = "avana";
        vm.serializeString(o, "network", c.network);
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeString(o, "release", c.release);
        vm.serializeAddress(o, "deployer", d.deployer);
        vm.serializeAddress(o, "create3Factory", d.factory);
        vm.serializeAddress(o, "timelock", d.timelock);
        vm.serializeString(o, "marketRegistry", _upgradeable("marketRegistry", d.marketRegistry));
        vm.serializeString(o, "parameterStore", _upgradeable("parameterStore", d.parameterStore));
        vm.serializeString(o, "riskModule", _upgradeable("riskModule", d.riskModule));
        vm.serializeString(o, "aaveAdapter", _upgradeable("aaveAdapter", d.aaveAdapter));
        vm.serializeString(o, "lpVaultSwap", _upgradeable("lpVaultSwap", d.lpVaultSwap));
        vm.serializeAddress(o, "lock", d.lock);
        vm.serializeAddress(o, "collateralization", d.collateralization);
        vm.serializeAddress(o, "vaultTokenFactory", d.vaultTokenFactory);
        vm.serializeAddress(o, "proxyManager", d.proxyManager);
        vm.serializeAddress(o, "payoutEscrow", d.payoutEscrow);
        vm.serializeAddress(o, "flashSource", d.flashSource);
        vm.serializeAddress(o, "flashLiquidator", d.flashLiquidator);
        vm.serializeAddress(o, "operatorHelpers", d.operatorHelpers);
        vm.serializeAddress(o, "lpVaults", d.lpVaults);
        uint256[] memory ids = new uint256[](c.integrations.length);
        string[] memory kinds = new string[](c.integrations.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            (ids[i], kinds[i]) = (c.integrations[i].integrationId, c.integrations[i].kind);
        }
        vm.serializeUint(o, "integrationIds", ids);
        vm.serializeString(o, "integrationKinds", kinds);
        vm.serializeAddress(o, "lens", d.lens);
        vm.serializeAddress(o, "lensModules", d.lensModules);
        vm.serializeAddress(o, "lensAaveSizing", d.lensAaveSizing);
        vm.serializeAddress(o, "debtOracleImplementation", d.debtOracleImplementation);
        vm.serializeAddress(o, "clOraclePricing", d.clOraclePricing);
        vm.serializeAddress(o, "clOracleModuleLogics", d.clOracleModuleLogics);
        vm.serializeAddress(o, "clOracleLogics", d.clOracleLogics);
        string memory json = vm.serializeUint(o, "deployedAtBlock", block.number);
        vm.writeJson(json, path);
    }

    function _upgradeable(
        string memory key,
        UpgradeableDeployment memory u
    ) private returns (string memory) {
        vm.serializeAddress(key, "proxy", u.proxy);
        vm.serializeAddress(key, "implementation", u.implementation);
        return vm.serializeAddress(key, "logics", u.logics);
    }
}
