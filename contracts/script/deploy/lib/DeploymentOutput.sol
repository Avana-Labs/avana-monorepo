// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaDeployment, ChainInputs} from "./DeployTypes.sol";
import {Script} from "forge-std/Script.sol";

/// @title DeploymentOutput
/// @notice Writes what `03_DeployAvana` deployed to `deployments-local/<network>/avana.json`, the input of the release
/// manifest producer (`packages/protocol`, `npm run manifest -- produce`), which adds code hashes, blocks and roles
/// read from the chain.
/// @dev One core stack per integration: `lpVaults`, `riskModules`, `liquidationModules`, `aaveAdapters` and
/// `flashloanRepays` are aligned with `integrationIds` (index `i` is the stack of `integrationIds[i]`).
/// `flashLiquidators` lists every operator flash liquidator, and `flashBorrowers` the contracts that need Aave V3's
/// `FLASH_BORROWER` (`06_AaveDeploymentPayload`). The markets are in `markets.json` (`09_ListMarkets`) and the loss
/// layers in `coverage.json` (`07_DeployFirstLossReserves`).
abstract contract DeploymentOutput is Script {
    function _writeAvanaOutput(
        string memory path,
        ChainInputs memory c,
        AvanaDeployment memory d
    ) internal {
        uint256 n = d.stacks.length;
        address[][5] memory cols;
        for (uint256 k = 0; k < 5; ++k) {
            cols[k] = new address[](n);
        }
        uint256[] memory ids = new uint256[](n);
        string[] memory kinds = new string[](n);
        uint256 nLiquidators;
        for (uint256 i = 0; i < n; ++i) {
            (ids[i], kinds[i]) = (d.stacks[i].integrationId, d.stacks[i].kind);
            cols[0][i] = d.stacks[i].lpVault;
            cols[1][i] = d.stacks[i].riskModule;
            cols[2][i] = d.stacks[i].liquidationModule;
            cols[3][i] = d.stacks[i].aaveAdapter;
            cols[4][i] = d.stacks[i].flashloanRepay;
            nLiquidators += d.stacks[i].flashLiquidators.length;
        }
        address[] memory liquidators = new address[](nLiquidators);
        uint256 j;
        for (uint256 i = 0; i < n; ++i) {
            for (uint256 h = 0; h < d.stacks[i].flashLiquidators.length; ++h) {
                liquidators[j++] = d.stacks[i].flashLiquidators[h];
            }
        }
        string memory o = "avana";
        vm.serializeString(o, "network", c.network);
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeString(o, "release", c.release);
        vm.serializeAddress(o, "deployer", d.deployer);
        vm.serializeAddress(o, "create3Factory", d.factory);
        vm.serializeAddress(o, "accessManager", d.accessManager);
        vm.serializeUint(o, "integrationIds", ids);
        vm.serializeString(o, "integrationKinds", kinds);
        vm.serializeAddress(o, "lpVaults", cols[0]);
        vm.serializeAddress(o, "riskModules", cols[1]);
        vm.serializeAddress(o, "liquidationModules", cols[2]);
        vm.serializeAddress(o, "aaveAdapters", cols[3]);
        vm.serializeAddress(o, "flashloanRepays", cols[4]);
        vm.serializeAddress(o, "flashLiquidators", liquidators);
        vm.serializeAddress(o, "flashBorrowers", liquidators);
        string memory json = vm.serializeUint(o, "deployedAtBlock", block.number);
        vm.writeJson(json, path);
    }
}
