// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/dependencies/aave/IAaveV4Hub.sol";
import {IFirstLossReserve} from "../../src/interfaces/IFirstLossReserve.sol";
import {AaveCalls} from "./lib/AaveCalls.sol";
import {IAccessManagerOps} from "./lib/AccessOperations.sol";
import {AvanaAccess} from "./lib/AvanaAccess.sol";

/// @notice The HubConfigurator call that lists a loss layer on its Hub asset (aave-v4 a3ef63e).
interface IHubConfiguratorAddSpoke {
    struct SpokeConfig {
        uint40 addCap;
        uint40 drawCap;
        uint24 riskPremiumThreshold;
        bool active;
        bool halted;
    }

    function addSpoke(
        address hub,
        address spoke,
        uint256 assetId,
        SpokeConfig calldata config
    ) external;
}

/// @title AaveLossLayersPayload
/// @notice Step 8, the Aave-side AIP `AvanaLossLayers` for every layer of `coverage.json` (`07_DeployFirstLossReserves`):
/// - each layer listed on its Hub asset (no draw), with `HUB_DEFICIT_ELIMINATOR_ROLE`;
/// - on the Aave AccessManager, its `coverDeficit` mapped to the coverage role, `setAllowedSpoke` and `setMinimum` to
///   the reserve-admin role, and `withdraw` to the withdraw role (`aavePayload.lossLayerRoles`);
/// - the executor holds the reserve-admin role with no delay and the withdraw role with the reserve's 14-day
///   `WITHDRAWAL_DELAY`; the coverage caller (`lossLayerRoles.coverageCaller`, default the executor) holds the
///   coverage role with no delay;
/// - each layer allows the CDP Spokes of its Hub (`aavePayload.hubs[h].cdpSpokes`) and takes its minimum.
/// @dev Only what is not on chain yet; a rerun with nothing new proposes nothing.
contract AaveLossLayersPayload is AaveCalls {
    /// @notice Aave V4's `Roles.HUB_DEFICIT_ELIMINATOR_ROLE` (a3ef63e).
    uint64 internal constant HUB_DEFICIT_ELIMINATOR_ROLE = 103;

    string internal cfg;
    address internal manager;
    address internal executor;
    uint64 internal coverageRole;
    uint64 internal adminRole;
    uint64 internal withdrawRole;

    function run() external {
        cfg = vm.readFile(_configPath(_network()));
        address controller;
        (executor, controller) = _executorOf(cfg);
        manager = _addr(cfg, ".aave.accessManager");
        string memory r = ".aavePayload.lossLayerRoles";
        coverageRole = uint64(vm.parseJsonUint(cfg, string.concat(r, ".coverageRole")));
        adminRole = uint64(vm.parseJsonUint(cfg, string.concat(r, ".reserveAdminRole")));
        withdrawRole = uint64(vm.parseJsonUint(cfg, string.concat(r, ".withdrawRole")));
        address coverageCaller = vm.keyExistsJson(cfg, string.concat(r, ".coverageCaller"))
            ? _addr(cfg, string.concat(r, ".coverageCaller"))
            : executor;

        string memory json = _coverageJson();
        require(bytes(json).length != 0, "no coverage.json: run 07-deploy-first-loss-reserves first");
        Calls memory k = _newCalls("AvanaLossLayers");
        _grant(k, adminRole, executor, 0, "reserve admin: executor");
        _grant(k, withdrawRole, executor, _withdrawalDelay(json), "withdraw: executor, 14 days");
        _grant(k, coverageRole, coverageCaller, 0, "coverage: caller");
        string[] memory labels = vm.parseJsonStringArray(json, ".hubLabels");
        address[] memory hubs = vm.parseJsonAddressArray(json, ".hubs");
        address[] memory assets = vm.parseJsonAddressArray(json, ".assets");
        address[] memory avana = vm.parseJsonAddressArray(json, ".avanaLayers");
        address[] memory offsets = vm.parseJsonAddressArray(json, ".daoOffsets");
        uint256[] memory minimums = vm.parseJsonUintArray(json, ".minimums");
        uint256[] memory offsetMinimums = vm.parseJsonUintArray(json, ".offsetMinimums");
        for (uint256 i = 0; i < hubs.length; ++i) {
            uint256 assetId = IAaveV4Hub(hubs[i]).getAssetId(assets[i]);
            address[] memory spokes = _cdpSpokes(labels[i]);
            _layer(k, hubs[i], assetId, avana[i], spokes, minimums[i]);
            _layer(k, hubs[i], assetId, offsets[i], spokes, offsetMinimums[i]);
        }
        _ship(k, executor, controller);
    }

    /// @notice The reserves' `WITHDRAWAL_DELAY` (14 days), read from the first deployed layer.
    function _withdrawalDelay(
        string memory json
    ) private view returns (uint32) {
        address[] memory avana = vm.parseJsonAddressArray(json, ".avanaLayers");
        require(avana.length != 0 && avana[0].code.length != 0, "no deployed First-Loss Reserve");
        return IFirstLossReserve(avana[0]).WITHDRAWAL_DELAY();
    }

    function _cdpSpokes(
        string memory hubLabel
    ) private view returns (address[] memory spokes) {
        uint256 n = _count(cfg, ".aavePayload.hubs");
        for (uint256 h = 0; h < n; ++h) {
            string memory hk = string.concat(".aavePayload.hubs[", vm.toString(h), "]");
            if (!_eq(vm.parseJsonString(cfg, string.concat(hk, ".label")), hubLabel)) continue;
            string[] memory names = vm.parseJsonStringArray(cfg, string.concat(hk, ".cdpSpokes"));
            spokes = new address[](names.length);
            for (uint256 s = 0; s < names.length; ++s) {
                spokes[s] = _spokeOf(cfg, names[s]);
            }
            return spokes;
        }
        revert(string.concat("no aavePayload.hubs entry ", hubLabel));
    }

    function _layer(
        Calls memory k,
        address hub,
        uint256 assetId,
        address layer,
        address[] memory spokes,
        uint256 minimum
    ) private view {
        require(layer.code.length != 0, "loss layer not deployed: run 07-deploy-first-loss-reserves");
        if (!IAaveV4Hub(hub).isSpokeListed(assetId, layer)) {
            IHubConfiguratorAddSpoke.SpokeConfig memory sc = IHubConfiguratorAddSpoke.SpokeConfig(
                IAaveV4Hub(hub).MAX_ALLOWED_SPOKE_CAP(), 0, IAaveV4Hub(hub).MAX_RISK_PREMIUM_THRESHOLD(), true, false
            );
            _call(
                k,
                _addr(cfg, ".aave.hubConfigurator"),
                abi.encodeCall(IHubConfiguratorAddSpoke.addSpoke, (hub, layer, assetId, sc)),
                "layer listed on its Hub asset"
            );
        }
        _grant(k, HUB_DEFICIT_ELIMINATOR_ROLE, layer, 0, "deficit eliminator: layer");
        _map(k, layer, AvanaAccess.reserveCoverageSelectors(), coverageRole, "coverDeficit");
        _map(k, layer, AvanaAccess.reserveAdminSelectors(), adminRole, "setAllowedSpoke, setMinimum");
        _map(k, layer, AvanaAccess.reserveWithdrawSelectors(), withdrawRole, "withdraw");
        for (uint256 s = 0; s < spokes.length; ++s) {
            if (IFirstLossReserve(layer).isAllowedSpoke(spokes[s])) continue;
            _call(k, layer, abi.encodeCall(IFirstLossReserve.setAllowedSpoke, (spokes[s], true)), "CDP Spoke allowed");
        }
        if (IFirstLossReserve(layer).minimum() != minimum) {
            _call(k, layer, abi.encodeCall(IFirstLossReserve.setMinimum, (minimum)), "minimum");
        }
    }

    function _grant(
        Calls memory k,
        uint64 role,
        address account,
        uint32 delay,
        string memory label
    ) private view {
        (bool member, uint32 current) = IAccessManagerOps(manager).hasRole(role, account);
        if (member && current == delay) return;
        _call(k, manager, abi.encodeCall(IAccessManagerOps.grantRole, (role, account, delay)), label);
    }

    function _map(
        Calls memory k,
        address target,
        bytes4[] memory selectors,
        uint64 role,
        string memory label
    ) private view {
        bool done = true;
        for (uint256 i = 0; i < selectors.length; ++i) {
            done = done && IAccessManagerOps(manager).getTargetFunctionRole(target, selectors[i]) == role;
        }
        if (done) return;
        _call(
            k,
            manager,
            abi.encodeCall(IAccessManagerOps.setTargetFunctionRole, (target, selectors, role)),
            string.concat("function role: ", label)
        );
    }
}
