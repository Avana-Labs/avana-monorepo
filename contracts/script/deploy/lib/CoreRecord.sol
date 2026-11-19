// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaCreate3Factory} from "../AvanaCreate3Factory.sol";
import {DeployBase} from "./DeployBase.sol";
import {CoreStack} from "./DeployTypes.sol";

/// @title CoreRecord
/// @notice Reads back what `03_DeployAvana` wrote to `deployments-local/<network>/avana.json`.
abstract contract CoreRecord is DeployBase {
    /// @notice The `avana.json` of this network; reverts when 03 has not run.
    function _avanaJson() internal view returns (string memory) {
        string memory path = _outputPath("avana");
        require(vm.exists(path), string.concat("missing ", path, ": run 03-avana first"));
        return vm.readFile(path);
    }

    /// @notice Sets the CREATE3 namespace of 03's deployment: its factory, its deployer (`AVANA_DEPLOYER`, else the
    /// script's sender, which must be 03's) and its release.
    function _useCoreNamespace() internal {
        string memory json = _avanaJson();
        deployer = vm.envOr("AVANA_DEPLOYER", msg.sender);
        require(deployer == vm.parseJsonAddress(json, ".deployer"), "the deployer is not the one 03-avana ran as");
        release = vm.parseJsonString(json, ".release");
        create3 = AvanaCreate3Factory(vm.parseJsonAddress(json, ".create3Factory"));
    }

    /// @notice Avana's AccessManager.
    function _accessManager() internal view returns (address) {
        return vm.parseJsonAddress(_avanaJson(), ".accessManager");
    }

    /// @notice Every core stack, in the order of `integrationIds`.
    function _stacks() internal view returns (CoreStack[] memory s) {
        string memory json = _avanaJson();
        uint256[] memory ids = vm.parseJsonUintArray(json, ".integrationIds");
        string[] memory kinds = vm.parseJsonStringArray(json, ".integrationKinds");
        address[] memory vaults = vm.parseJsonAddressArray(json, ".lpVaults");
        address[] memory risk = vm.parseJsonAddressArray(json, ".riskModules");
        address[] memory liq = vm.parseJsonAddressArray(json, ".liquidationModules");
        address[] memory adapters = vm.parseJsonAddressArray(json, ".aaveAdapters");
        address[] memory repays = vm.parseJsonAddressArray(json, ".flashloanRepays");
        s = new CoreStack[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            s[i].integrationId = uint32(ids[i]);
            s[i].kind = kinds[i];
            s[i].lpVault = vaults[i];
            s[i].riskModule = risk[i];
            s[i].liquidationModule = liq[i];
            s[i].aaveAdapter = adapters[i];
            s[i].flashloanRepay = repays[i];
        }
    }

    /// @notice The core stack of `integrationId`; reverts when 03 deployed none.
    function _stackOf(
        uint32 integrationId
    ) internal view returns (CoreStack memory) {
        CoreStack[] memory s = _stacks();
        for (uint256 i = 0; i < s.length; ++i) {
            if (s[i].integrationId == integrationId) return s[i];
        }
        revert(string.concat("no core stack for integration ", vm.toString(integrationId)));
    }

    // ─── Config ───

    /// @notice The Hub labelled `label` in `aave.hubs`.
    function _hubOf(
        string memory cfg,
        string memory label
    ) internal view returns (address) {
        uint256 n = _count(cfg, ".aave.hubs");
        for (uint256 i = 0; i < n; ++i) {
            string memory k = string.concat(".aave.hubs[", vm.toString(i), "]");
            if (_eq(vm.parseJsonString(cfg, string.concat(k, ".label")), label)) {
                return _addr(cfg, string.concat(k, ".hub"));
            }
        }
        revert(string.concat("no aave.hubs entry ", label));
    }

    /// @notice The Spoke labelled `label` in `aave.spokes`.
    function _spokeOf(
        string memory cfg,
        string memory label
    ) internal view returns (address) {
        return _addr(cfg, string.concat(".aave.spokes.", label));
    }

    /// @notice The output `coverage.json` of `07_DeployFirstLossReserves`, "" before it ran.
    function _coverageJson() internal view returns (string memory) {
        string memory path = _outputPath("coverage");
        return vm.exists(path) ? vm.readFile(path) : "";
    }

    /// @notice Avana's First-Loss Reserve of `(hub, asset)` from `coverage.json`, zero when there is none.
    function _firstLossReserveOf(
        address hub,
        address asset
    ) internal view returns (address) {
        string memory json = _coverageJson();
        if (bytes(json).length == 0) return address(0);
        address[] memory hubs = vm.parseJsonAddressArray(json, ".hubs");
        address[] memory assets = vm.parseJsonAddressArray(json, ".assets");
        address[] memory layers = vm.parseJsonAddressArray(json, ".avanaLayers");
        for (uint256 i = 0; i < hubs.length; ++i) {
            if (hubs[i] == hub && assets[i] == asset) return layers[i];
        }
        return address(0);
    }
}
