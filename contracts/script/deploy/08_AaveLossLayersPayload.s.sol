// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAvanaFirstLossReserve} from "../../src/coverage/first-loss-reserve/IAvanaFirstLossReserve.sol";
import {
    AFlags,
    ARoleMembership,
    ARoleUpdate,
    ASpokeAssetConfig,
    ASpokeConfig,
    ASpokeToAssetsAddition,
    ATargetFunctionRoleUpdate,
    AavePayloads,
    IAaveHubLimits,
    IAaveListedViews
} from "./lib/AavePayloads.sol";
import {console2} from "forge-std/console2.sol";

/// @notice What 08 reads to leave out what is already on chain: role labels and members on Aave's AccessManager, and
/// a loss layer's allowlist.
interface ILossLayerViews {
    function isRoleLabeled(
        uint64 roleId
    ) external view returns (bool);
    function hasRole(
        uint64 roleId,
        address account
    ) external view returns (bool isMember, uint32 executionDelay);
    function allowedBorrowSpoke(
        address spoke
    ) external view returns (bool);
}

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
/// one `DaoDeficitOffset` behind each Avana Umbrella (First-Loss Reserve, deployed by Avana in `07_DeployAvanaFirstLossReserves`
/// and named here by address), then one Aave V4 payload on the config engine that
/// - grants `HUB_DEFICIT_ELIMINATOR_ROLE` to both layers, labels the loss-layer roles and maps `coverDeficit` to
///   `COVERAGE_ROLE` (the Emergency Guardian and the Aave Protocol Guardian), the reserve administration to
///   `RESERVE_ADMIN_ROLE` (the governance executor) and `withdraw` to `WITHDRAW_ROLE` (the governance executor with a
///   14-day execution delay, the withdrawal delay: it schedules, and executes 14 days later); the Aave DAO is the
///   guardian of the three roles, so it can cancel a scheduled withdrawal;
/// - registers both layers supply-only on their Hub asset (`addCap = MAX_ALLOWED_SPOKE_CAP`, `drawCap = 0`);
/// - in `_postExecute`, as the executor: allowlists the Hub's CDP Spokes on both, sets each `firstLossReserveMinimum`
///   and funds the DAO offset to its minimum from the treasury. Avana Labs then funds the Umbrella (step `fund`).
/// @dev The three role IDs are settings (`aavePayload.lossLayerRoles`): 500, 501 and 503 on local and test networks, the IDs
/// Aave governance assigns before mainnet (Aave allocates role IDs by domain range; 500, 501 and 503 may collide). On Ethereum
/// and Base the script refuses the placeholder values and writes the actions only.
contract AaveLossLayersPayload is AavePayloads {
    /// @notice Aave Hub role of a deficit eliminator (`Roles.HUB_DEFICIT_ELIMINATOR_ROLE`).
    uint64 internal constant HUB_DEFICIT_ELIMINATOR_ROLE = 103;

    /// @notice The AccessManager's admin role, held by the Aave DAO.
    uint64 internal constant ADMIN_ROLE = 0;

    /// @notice Execution delay of `WITHDRAW_ROLE`: 14 days, the First-Loss Reserve's withdrawal delay.
    uint32 internal constant RESERVE_WITHDRAW_DELAY = 14 days;

    string internal cfg;
    address internal executor;
    address internal am;
    uint64 internal coverageRole;
    uint64 internal reserveAdminRole;
    uint64 internal withdrawRole;
    bool internal execute;
    string internal offsetsJson;

    function run() external {
        cfg = vm.readFile(_configPath(_network()));
        execute = block.chainid != 1 && block.chainid != 8453;
        executor = _addr(cfg, ".aave.governanceExecutor");
        am = _addr(cfg, ".aave.accessManager");
        coverageRole = uint64(vm.parseJsonUint(cfg, ".aavePayload.lossLayerRoles.coverageRole"));
        reserveAdminRole = uint64(vm.parseJsonUint(cfg, ".aavePayload.lossLayerRoles.reserveAdminRole"));
        withdrawRole = uint64(vm.parseJsonUint(cfg, ".aavePayload.lossLayerRoles.withdrawRole"));
        require(
            coverageRole != reserveAdminRole && coverageRole != withdrawRole && reserveAdminRole != withdrawRole
                && coverageRole > 0 && reserveAdminRole > 0 && withdrawRole > 0,
            "lossLayerRoles"
        );
        require(
            execute || (coverageRole != 500 && reserveAdminRole != 501 && withdrawRole != 503),
            "mainnet: set aavePayload.lossLayerRoles to the role IDs Aave governance assigns"
        );
        address controller = execute ? _addr(cfg, ".aaveLocal.payloadsController") : address(0);
        deployer = controller;
        Builder memory b = _newBuilder();
        _roles(b);
        (uint256 nHubs, uint256 nAssets) = (_count(cfg, ".aavePayload.hubs"), _count(cfg, ".aavePayload.debtAssets"));
        string memory coverage = vm.readFile(_outputPath("coverage"));
        offsetsJson = _keepOutput("offsets", "deficit-offsets");
        bool added;
        for (uint256 h = 0; h < nHubs; ++h) {
            for (uint256 i = 0; i < nAssets; ++i) {
                if (_coveredPair(cfg, h, i)) added = _pair(b, coverage, h, i) || added;
            }
        }
        if (added) vm.writeJson(offsetsJson, _outputPath("deficit-offsets"));
        _shipPayload("AvanaLossLayers", b, _addr(cfg, ".aave.configEngine"), executor, controller, execute);
    }

    /// @notice The three role labels, `COVERAGE_ROLE` for both guardians, `RESERVE_ADMIN_ROLE` for the executor and
    /// `WITHDRAW_ROLE` for the executor with the 14-day withdrawal delay.
    function _roles(
        Builder memory b
    ) private view {
        if (!ILossLayerViews(am).isRoleLabeled(coverageRole)) {
            _roleUpdate(b, _label(coverageRole, "AVANA_COVERAGE_ROLE"));
        }
        if (!ILossLayerViews(am).isRoleLabeled(reserveAdminRole)) {
            _roleUpdate(b, _label(reserveAdminRole, "AVANA_RESERVE_ADMIN_ROLE"));
        }
        if (!ILossLayerViews(am).isRoleLabeled(withdrawRole)) {
            _roleUpdate(b, _label(withdrawRole, "AVANA_RESERVE_WITHDRAW_ROLE"));
        }
        _grant(b, coverageRole, _addr(cfg, ".governance.emergencyGuardian"), 0);
        _grant(b, coverageRole, _addr(cfg, ".governance.aaveProtocolGuardian"), 0);
        _grant(b, reserveAdminRole, executor, 0);
        _grant(b, withdrawRole, executor, RESERVE_WITHDRAW_DELAY);
    }

    function _label(
        uint64 role,
        string memory label
    ) private view returns (ARoleUpdate memory u) {
        u = ARoleUpdate({
            authority: am,
            roleId: role,
            admin: AFlags.KEEP_CURRENT_UINT64,
            // The Aave DAO (the manager's admin role, 0) is the guardian of the role: it can cancel scheduled calls.
            guardian: ADMIN_ROLE,
            grantDelay: AFlags.KEEP_CURRENT_UINT32,
            label: label,
            labelUpdate: false
        });
    }

    function _grant(
        Builder memory b,
        uint64 role,
        address account,
        uint32 executionDelay
    ) private view {
        (bool member, uint32 delay) = ILossLayerViews(am).hasRole(role, account);
        if (!member || delay != executionDelay) {
            _roleMembership(b, ARoleMembership(am, role, account, true, executionDelay));
        }
    }

    /// @notice One (Hub, asset): the DAO offset deployed behind the Umbrella, both layers wired. A pair wired by an
    /// earlier run only gets the CDP Spokes the config adds to its Hub allowlisted on both layers.
    /// @return isNew Whether the pair was wired by this run.
    function _pair(
        Builder memory b,
        string memory coverage,
        uint256 h,
        uint256 i
    ) private returns (bool isNew) {
        string memory hk = string.concat(".aavePayload.hubs[", vm.toString(h), "]");
        string memory ak = string.concat(".aavePayload.debtAssets[", vm.toString(i), "]");
        string memory label = vm.parseJsonString(cfg, string.concat(hk, ".label"));
        string memory symbol = vm.parseJsonString(cfg, string.concat(ak, ".symbol"));
        address cs = vm.parseJsonAddress(coverage, string.concat("$['AvanaFirstLossReserve.", label, ".", symbol, "']"));
        uint256 unit = 10 ** vm.parseJsonUint(cfg, string.concat(ak, ".decimals"));
        string[] memory cdps = vm.parseJsonStringArray(cfg, string.concat(hk, ".cdpSpokes"));
        {
            IAvanaFirstLossReserve c = IAvanaFirstLossReserve(cs);
            if (IAaveListedViews(c.HUB()).isSpokeListed(c.ASSET_ID(), cs)) {
                address done = execute
                    ? _recorded("deficit-offsets", string.concat("$['DaoDeficitOffset.", label, ".", symbol, "']"))
                    : _addr(cfg, string.concat(ak, ".daoDeficitOffsets.", label));
                _allowNewSpokes(b, cs, cdps);
                _allowNewSpokes(b, done, cdps);
                return false;
            }
        }
        isNew = true;
        address dos;
        if (execute) {
            IAvanaFirstLossReserve c = IAvanaFirstLossReserve(cs);
            bytes memory initCode = bytes.concat(
                _artifact("DaoDeficitOffset.sol", "DaoDeficitOffset"),
                abi.encode(c.HUB(), c.ASSET(), c.ASSET_ID(), am, cs)
            );
            vm.broadcast(deployer);
            dos = _deploy(string.concat("DaoDeficitOffset.", label, ".", symbol), initCode);
            offsetsJson = vm.serializeAddress("offsets", string.concat("DaoDeficitOffset.", label, ".", symbol), dos);
            console2.log("DaoDeficitOffset", label, symbol, dos);
        } else {
            dos = _addr(cfg, string.concat(ak, ".daoDeficitOffsets.", label));
        }
        _layer(b, cs, cdps, vm.parseJsonUint(cfg, string.concat(ak, ".coverageMinimum")) * unit, 0);
        uint256 offset = vm.parseJsonUint(cfg, string.concat(ak, ".offsetMinimum")) * unit;
        _layer(b, dos, cdps, offset, offset);
        if (execute && offset != 0) {
            // Test-network faucet: the DAO treasury's offset funding reaches the executor before the AIP runs.
            ILayerFunding asset = ILayerFunding(IAvanaFirstLossReserve(cs).ASSET());
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
        IAvanaFirstLossReserve c = IAvanaFirstLossReserve(layer);
        address hub = c.HUB();
        _grant(b, HUB_DEFICIT_ELIMINATOR_ROLE, layer, 0);
        bytes4[] memory cover = new bytes4[](1);
        cover[0] = IAvanaFirstLossReserve.coverDeficit.selector;
        bytes4[] memory admin = new bytes4[](2);
        admin[0] = IAvanaFirstLossReserve.setAllowedBorrowSpoke.selector;
        admin[1] = IAvanaFirstLossReserve.setFirstLossReserveMinimum.selector;
        bytes4[] memory withdraw = new bytes4[](1);
        withdraw[0] = IAvanaFirstLossReserve.withdraw.selector;
        _targetFunctionRole(b, ATargetFunctionRoleUpdate(am, layer, cover, coverageRole));
        _targetFunctionRole(b, ATargetFunctionRoleUpdate(am, layer, admin, reserveAdminRole));
        _targetFunctionRole(b, ATargetFunctionRoleUpdate(am, layer, withdraw, withdrawRole));
        ASpokeToAssetsAddition memory add;
        add.hubConfigurator = _addr(cfg, ".aave.hubConfigurator");
        add.hub = hub;
        add.spoke = layer;
        add.assets = new ASpokeAssetConfig[](1);
        add.assets[0] = ASpokeAssetConfig(
            c.ASSET(),
            ASpokeConfig(
                IAaveHubLimits(hub).MAX_ALLOWED_SPOKE_CAP(),
                0,
                IAaveHubLimits(hub).MAX_RISK_PREMIUM_THRESHOLD(),
                true,
                false
            )
        );
        _spokeToAssets(b, add);
        for (uint256 s = 0; s < cdps.length; ++s) {
            address spoke = _cdp(cdps[s]);
            _postCall(b, layer, abi.encodeCall(IAvanaFirstLossReserve.setAllowedBorrowSpoke, (spoke, true)));
        }
        _postCall(b, layer, abi.encodeCall(IAvanaFirstLossReserve.setFirstLossReserveMinimum, (minimum)));
        if (fund != 0) {
            _postCall(b, c.ASSET(), abi.encodeCall(ILayerFunding.approve, (layer, fund)));
            _postCall(b, layer, abi.encodeCall(IAvanaFirstLossReserve.fund, (fund)));
        }
    }

    /// @notice The config's CDP Spokes of a wired pair's Hub that its loss layer does not allow yet.
    function _allowNewSpokes(
        Builder memory b,
        address layer,
        string[] memory cdps
    ) private view {
        for (uint256 s = 0; s < cdps.length; ++s) {
            address spoke = _cdp(cdps[s]);
            if (ILossLayerViews(layer).allowedBorrowSpoke(spoke)) continue;
            _postCall(b, layer, abi.encodeCall(IAvanaFirstLossReserve.setAllowedBorrowSpoke, (spoke, true)));
        }
    }

    function _cdp(
        string memory label
    ) private view returns (address) {
        return _addr(cfg, string.concat(".aave.spokes.", label));
    }
}
