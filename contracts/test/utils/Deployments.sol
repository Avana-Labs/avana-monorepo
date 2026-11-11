// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AaveV4Fixture} from "./fixtures/AaveV4Fixture.sol";

/// @title Deployments
/// @notice Writes the manifest of a local deployment to `contracts/deployments-local/<chainId>-<label>.json`, the only
/// read-write path of `fs_permissions`, and reads it back.
/// @dev The Aave section uses Aave's report keys (`accessManager`, `hubConfigurator`, `spokeConfigurator`,
/// `treasurySpoke`, `hub.<label>`, `spoke.<label>`, `oracle.<label>`, plus `liquidationLogic`). The Avana section is
/// added with the first Avana contract the fixture deploys. Tests never write under `deployments/`.
abstract contract Deployments is AaveV4Fixture {
    string internal constant MANIFEST_DIR = "deployments-local";

    /// @notice Path of the local manifest for `label` on the current chain.
    function _manifestPath(
        string memory label
    ) internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/", MANIFEST_DIR, "/", vm.toString(block.chainid), "-", label, ".json");
    }

    /// @notice Serialises the Aave V4 section of the fixture and writes the manifest.
    function _writeManifest(
        string memory label
    ) internal returns (string memory path) {
        string memory key = "aave";
        vm.serializeAddress(key, "accessManager", aave.accessManager);
        vm.serializeAddress(key, "hubConfigurator", aave.hubConfigurator);
        vm.serializeAddress(key, "spokeConfigurator", aave.spokeConfigurator);
        vm.serializeAddress(key, "treasurySpoke", aave.treasurySpoke);
        vm.serializeAddress(key, string.concat("hub.", HUB_STABLE_LP), aave.hub);
        vm.serializeAddress(key, string.concat("spoke.", SPOKE_CDP_UNISWAP_V3_STABLE), aave.cdpSpoke);
        vm.serializeAddress(key, string.concat("oracle.", SPOKE_CDP_UNISWAP_V3_STABLE), aave.cdpOracle);
        vm.serializeAddress(key, string.concat("spoke.", SPOKE_LEND), aave.lendSpoke);
        vm.serializeAddress(key, string.concat("oracle.", SPOKE_LEND), aave.lendOracle);
        string memory aaveJson = vm.serializeAddress(key, "liquidationLogic", aave.liquidationLogic);

        string memory root = "manifest";
        vm.serializeUint(root, "chainId", block.chainid);
        string memory json = vm.serializeString(root, "aave", aaveJson);
        vm.createDir(string.concat(vm.projectRoot(), "/", MANIFEST_DIR), true);
        path = _manifestPath(label);
        vm.writeJson(json, path);
    }

    /// @notice Reads an address from a manifest, for example `.aave["hub.stable-lp"]`.
    function _readManifestAddress(
        string memory path,
        string memory jsonPath
    ) internal view returns (address) {
        return vm.parseJsonAddress(vm.readFile(path), jsonPath);
    }
}
