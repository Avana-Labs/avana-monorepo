// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICoverageSpoke} from "../../src/coverage/coverage-spoke/ICoverageSpoke.sol";
import {ICoverageSpokeAdmin} from "../../src/coverage/coverage-spoke/ICoverageSpokeAdmin.sol";
import {AFlags, ARoleMembership, ARoleUpdate, ASpokeAssetConfig, ASpokeConfig, ASpokeToAssetsAddition, ATargetFunctionRoleUpdate, IAaveHubLimits, AavePayloads} from "./lib/AavePayloads.sol";
import {console2} from "forge-std/console2.sol";

interface ILayerFunding {
    function mint(
        address to,
        uint256 amount
    ) external;
    function approve(
        address spender,
        uint256 amount
    ) external returns (bool);
}

/// @title AaveLossLayersPayload
/// @notice The Aave DAO's loss-layer AIP (2.14, `REQ-FLR-007`, `REQ-FLR-046`, `REQ-FLR-047`): the DAO-side deployment of
/// one `DeficitOffsetSpoke` behind each Avana Umbrella (Coverage Spoke, deployed by Avana in `07_DeployCoverageSpokes`
/// and named here by address), then one Aave V4 payload on the config engine that
/// - grants `HUB_DEFICIT_ELIMINATOR_ROLE` to both layers, labels the loss-layer roles and maps `coverDeficit` to
///   `COVERAGE_ROLE` (the Emergency Guardian and the Aave Protocol Guardian) and the reserve administration to
///   `RESERVE_ADMIN_ROLE` (the governance executor);
/// - registers both layers supply-only on their Hub asset (`addCap = MAX_ALLOWED_SPOKE_CAP`, `drawCap = 0`);
/// - in `_postExecute`, as the executor: allowlists the Hub's CDP Spokes on both, sets each `firstLossReserveMinimum`
///   and funds the DAO offset to its minimum from the treasury. Avana Labs then funds the Umbrella (step `fund`).
/// @dev The two role IDs are settings (`aavePayload.lossLayerRoles`): 500 and 501 on local and test networks, the IDs
/// Aave governance assigns before mainnet (Aave allocates role IDs by domain range; 500/501 may collide). On Ethereum
/// and Base the script refuses the placeholder values and writes the actions only.
contract AaveLossLayersPayload is AavePayloads {
    /// @notice Aave Hub role of a deficit eliminator (`Roles.HUB_DEFICIT_ELIMINATOR_ROLE`).
    uint64 internal constant HUB_DEFICIT_ELIMINATOR_ROLE = 103;

    string internal cfg;
    address internal executor;
    address internal am;
    uint64 internal coverageRole;
    uint64 internal reserveAdminRole;
    bool internal execute;
    string internal offsetsJson;

    function run() external {
        cfg = vm.readFile(string.concat(vm.projectRoot(), "/script/deploy/config/", _network(), ".json"));
        execute = block.chainid != 1 && block.chainid != 8453;
        executor = _addr(cfg, ".aave.governanceExecutor");
        am = _addr(cfg, ".aave.accessManager");
        coverageRole = uint64(vm.parseJsonUint(cfg, ".aavePayload.lossLayerRoles.coverageRole"));
        reserveAdminRole = uint64(vm.parseJsonUint(cfg, ".aavePayload.lossLayerRoles.reserveAdminRole"));
        require(coverageRole != reserveAdminRole && coverageRole > 0 && reserveAdminRole > 0, "lossLayerRoles");
        require(
            execute || (coverageRole != 500 && reserveAdminRole != 501),
            "mainnet: set aavePayload.lossLayerRoles to the role IDs Aave governance assigns"
        );
        address controller = execute ? _addr(cfg, ".aaveLocal.payloadsController") : address(0);
        deployer = controller;
        Builder memory b = _newBuilder();
        _roles(b);
        (uint256 nHubs, uint256 nAssets) =
            (_count(cfg, ".aavePayload.hubs"), _count(cfg, ".aavePayload.debtAssets"));
        string memory coverage = vm.readFile(_outputPath("coverage"));
        for (uint256 h = 0; h < nHubs; ++h) {
            for (uint256 i = 0; i < nAssets; ++i) {
                _pair(b, coverage, h, i);
            }
        }
        if (bytes(offsetsJson).length != 0) vm.writeJson(offsetsJson, _outputPath("deficit-offsets"));
        _shipPayload("AvanaLossLayers", b, _addr(cfg, ".aave.configEngine"), executor, controller, execute);
    }

    /// @notice The two role labels, `COVERAGE_ROLE` for both guardians, `RESERVE_ADMIN_ROLE` for the executor.
    function _roles(
        Builder memory b
    ) private view {
        _roleUpdate(b, _label(coverageRole, "AVANA_COVERAGE_ROLE"));
        _roleUpdate(b, _label(reserveAdminRole, "AVANA_RESERVE_ADMIN_ROLE"));
        _grant(b, coverageRole, _addr(cfg, ".governance.emergencyGuardian"));
        _grant(b, coverageRole, _addr(cfg, ".governance.aaveProtocolGuardian"));
        _grant(b, reserveAdminRole, executor);
    }

    function _label(
        uint64 role,
        string memory label
    ) private view returns (ARoleUpdate memory u) {
        u = ARoleUpdate({
            authority: am,
            roleId: role,
            admin: AFlags.KEEP_CURRENT_UINT64,
            guardian: AFlags.KEEP_CURRENT_UINT64,
            grantDelay: AFlags.KEEP_CURRENT_UINT32,
            label: label,
            labelUpdate: false
        });
    }

    function _grant(
        Builder memory b,
        uint64 role,
        address account
    ) private view {
        _roleMembership(b, ARoleMembership(am, role, account, true, 0));
    }

    /// @notice One (Hub, asset): the DAO offset deployed behind the Umbrella, both layers wired.
    function _pair(
        Builder memory b,
        string memory coverage,
        uint256 h,
        uint256 i
    ) private {
        string memory hk = string.concat(".aavePayload.hubs[", vm.toString(h), "]");
        string memory ak = string.concat(".aavePayload.debtAssets[", vm.toString(i), "]");
        string memory label = vm.parseJsonString(cfg, string.concat(hk, ".label"));
        string memory symbol = vm.parseJsonString(cfg, string.concat(ak, ".symbol"));
        address cs = vm.parseJsonAddress(coverage, string.concat("$['CoverageSpoke.", label, ".", symbol, "']"));
        uint256 unit = 10 ** vm.parseJsonUint(cfg, string.concat(ak, ".decimals"));
        address dos;
        if (execute) {
            ICoverageSpoke c = ICoverageSpoke(cs);
            bytes memory initCode = bytes.concat(
                _artifact("DeficitOffsetSpoke.sol", "DeficitOffsetSpoke"),
                abi.encode(c.HUB(), c.ASSET(), c.ASSET_ID(), am, uint256(1_209_600), cs)
            );
            vm.broadcast(deployer);
            dos = _deploy(string.concat("DeficitOffsetSpoke.", label, ".", symbol), initCode);
            offsetsJson = vm.serializeAddress("offsets", string.concat("DeficitOffsetSpoke.", label, ".", symbol), dos);
            console2.log("DeficitOffsetSpoke", label, symbol, dos);
        } else {
            dos = _addr(cfg, string.concat(ak, ".deficitOffsetSpokes.", label));
        }
        string[] memory cdps = vm.parseJsonStringArray(cfg, string.concat(hk, ".cdpSpokes"));
        _layer(b, cs, cdps, vm.parseJsonUint(cfg, string.concat(ak, ".coverageMinimum")) * unit, 0);
        uint256 offset = vm.parseJsonUint(cfg, string.concat(ak, ".offsetMinimum")) * unit;
        _layer(b, dos, cdps, offset, offset);
        if (execute && offset != 0) {
            // Test-network faucet: the DAO treasury's offset funding reaches the executor before the AIP runs.
            ILayerFunding asset = ILayerFunding(ICoverageSpoke(cs).ASSET());
            vm.broadcast(_addr(cfg, ".aavePayload.tokenMinter"));
            asset.mint(executor, offset);
        }
    }

    /// @notice One loss layer: `HUB_DEFICIT_ELIMINATOR_ROLE`, its selector roles, supply-only on its Hub asset, the CDP
    /// Spokes allowlisted, its minimum and, for the DAO offset, its funding.
    function _layer(
        Builder memory b,
        address layer,
        string[] memory cdps,
        uint256 minimum,
        uint256 fund
    ) private view {
        ICoverageSpoke c = ICoverageSpoke(layer);
        address hub = c.HUB();
        _grant(b, HUB_DEFICIT_ELIMINATOR_ROLE, layer);
        bytes4[] memory cover = new bytes4[](1);
        cover[0] = ICoverageSpoke.coverDeficit.selector;
        bytes4[] memory admin = new bytes4[](5);
        admin[0] = ICoverageSpokeAdmin.setAllowedBorrowSpoke.selector;
        admin[1] = ICoverageSpokeAdmin.setFirstLossReserveMinimum.selector;
        admin[2] = ICoverageSpokeAdmin.requestWithdrawal.selector;
        admin[3] = ICoverageSpokeAdmin.cancelWithdrawal.selector;
        admin[4] = ICoverageSpokeAdmin.executeWithdrawal.selector;
        _targetFunctionRole(b, ATargetFunctionRoleUpdate(am, layer, cover, coverageRole));
        _targetFunctionRole(b, ATargetFunctionRoleUpdate(am, layer, admin, reserveAdminRole));
        ASpokeToAssetsAddition memory add;
        add.hubConfigurator = _addr(cfg, ".aave.hubConfigurator");
        add.hub = hub;
        add.spoke = layer;
        add.assets = new ASpokeAssetConfig[](1);
        add.assets[0] = ASpokeAssetConfig(
            c.ASSET(),
            ASpokeConfig(IAaveHubLimits(hub).MAX_ALLOWED_SPOKE_CAP(), 0, IAaveHubLimits(hub).MAX_RISK_PREMIUM_THRESHOLD(), true, false)
        );
        _spokeToAssets(b, add);
        for (uint256 s = 0; s < cdps.length; ++s) {
            address spoke = _cdp(cdps[s]);
            _postCall(b, layer, abi.encodeCall(ICoverageSpokeAdmin.setAllowedBorrowSpoke, (spoke, true)));
        }
        _postCall(b, layer, abi.encodeCall(ICoverageSpokeAdmin.setFirstLossReserveMinimum, (minimum)));
        if (fund != 0) {
            _postCall(b, c.ASSET(), abi.encodeCall(ILayerFunding.approve, (layer, fund)));
            _postCall(b, layer, abi.encodeCall(ICoverageSpoke.fund, (fund)));
        }
    }

    function _cdp(
        string memory label
    ) private view returns (address) {
        return _addr(cfg, string.concat(".aave.spokes.", label));
    }
}
