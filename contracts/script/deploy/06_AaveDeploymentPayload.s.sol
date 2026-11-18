// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AaveGuardianRole} from "./lib/AaveGuardianRole.sol";
import {
    AAssetListing,
    ADynamicReserveConfig,
    AFlags,
    AInterestRateData,
    ALiquidationConfigUpdate,
    AReserveConfig,
    AReserveListing,
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

/// @notice The Aave AccessManager's views the Guardian grant reads, so a rerun adds only what is missing.
interface IGuardianAccessViews {
    function isRoleLabeled(
        uint64 roleId
    ) external view returns (bool);
    function hasRole(
        uint64 roleId,
        address account
    ) external view returns (bool isMember, uint32 executionDelay);
    function getTargetFunctionRole(
        address target,
        bytes4 selector
    ) external view returns (uint64);
}

interface IFlashAcl {
    function addFlashBorrower(
        address borrower
    ) external;
    function isFlashBorrower(
        address borrower
    ) external view returns (bool);
}

interface ITestTokenMint {
    function mint(
        address to,
        uint256 amount
    ) external;
    function approve(
        address spender,
        uint256 amount
    ) external returns (bool);
}

interface ILendSpoke {
    function getReserveId(
        address hub,
        uint256 assetId
    ) external view returns (uint256);
    function supply(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256, uint256);
    function getUserSuppliedAssets(
        uint256 reserveId,
        address user
    ) external view returns (uint256);
}

/// @title AaveDeploymentPayload
/// @notice The Aave-side deployment AIPs (governance README, "Deployment AIP (per chain)"), each an Aave V4 payload on
/// Aave's config engine run by the governance executor, kept apart from Avana's own deployment: they name Avana's
/// contracts only by address.
/// - `AvanaDeployment`: for every Hub and every debt asset of `aavePayload.debtAssets`, the Hub asset with its kinked rate
///   curve; the Lend Spoke on it (open to lenders, no draw) and each CDP Spoke of that Hub (its draw cap, no supply);
///   the debt reserves on those Spokes, the CDP ones not borrowable (Avana's `deployCdpSpoke` requires every borrowable
///   reserve to be an approved debt reserve, and `enableDebtReserve` comes later); each CDP Spoke's liquidation
///   configuration (target health factor 1.10, the bonus curve).
/// - `AvanaBootstrapSupply` (test networks): the DAO treasury's bootstrap supply of each Lend Spoke, from the executor.
/// - `AvanaFlashBorrowers` (Aave V3): `FLASH_BORROWER` for Avana's flash source and the public flash liquidation helper.
/// @dev On Ethereum and Base the script writes the payloads' actions only (`aip-<name>.json`) for the AIP author; on
/// test networks it deploys and executes them as the PayloadsController stand-in. First-Loss Reserves and the DAO
/// deficit offsets are registered by their own AIP (`08_AaveLossLayersPayload`) once they are deployed.
contract AaveDeploymentPayload is AavePayloads {
    string internal cfg;
    address internal executor;
    address internal controller;
    address internal engine;
    bool internal execute;

    function run() external {
        cfg = vm.readFile(_configPath(_network()));
        execute = block.chainid != 1 && block.chainid != 8453;
        executor = _addr(cfg, ".aave.governanceExecutor");
        controller = execute ? _addr(cfg, ".aaveLocal.payloadsController") : address(0);
        engine = _addr(cfg, ".aave.configEngine");
        // DAO-side contracts (the payloads and their data) come from the PayloadsController stand-in, never Avana's
        // deployer: the two deployments only exchange addresses.
        deployer = controller;
        _shipPayload("AvanaDeployment", _deployment(), engine, executor, controller, execute);
        if (execute) _shipPayload("AvanaBootstrapSupply", _bootstrap(), engine, executor, controller, true);
        _shipPayload("AvanaFlashBorrowers", _flashBorrowers(), engine, executor, controller, execute);
    }

    function _hub(
        string memory label
    ) private view returns (address) {
        uint256 n = _count(cfg, ".aave.hubs");
        for (uint256 i = 0; i < n; ++i) {
            string memory k = string.concat(".aave.hubs[", vm.toString(i), "]");
            if (_eq(vm.parseJsonString(cfg, string.concat(k, ".label")), label)) {
                return _addr(cfg, string.concat(k, ".hub"));
            }
        }
        revert(string.concat("no aave.hubs entry ", label));
    }

    function _spoke(
        string memory label
    ) private view returns (address) {
        return _addr(cfg, string.concat(".aave.spokes.", label));
    }

    function _hk(
        uint256 h
    ) private pure returns (string memory) {
        return string.concat(".aavePayload.hubs[", vm.toString(h), "]");
    }

    function _ak(
        uint256 i
    ) private pure returns (string memory) {
        return string.concat(".aavePayload.debtAssets[", vm.toString(i), "]");
    }

    /// @notice Whether `spoke` is on Hub asset `token` already (its reserve is listed in the same AIP action).
    function _spokeOn(
        address hub,
        address token,
        address spoke
    ) private view returns (bool) {
        if (!IAaveListedViews(hub).isUnderlyingListed(token)) return false;
        return IAaveListedViews(hub).isSpokeListed(IAaveHubLimits(hub).getAssetId(token), spoke);
    }

    function _deployment() private view returns (Builder memory b) {
        b = _newBuilder();
        uint256 nHubs = _count(cfg, ".aavePayload.hubs");
        for (uint256 h = 0; h < nHubs; ++h) {
            _hubAssets(b, h);
            _hubSpokes(b, h);
        }
        _guardianRole(b);
    }

    /// @notice REQ-ACCESS-070: the Aave Protocol Guardian's one-way `freezeReserve` and `pauseReserve` on the
    /// chain's SpokeConfigurator, in a role of their own that the Guardian and the Domain Admin (the executor) hold.
    function _guardianRole(
        Builder memory b
    ) private view {
        address am = _addr(cfg, ".aave.accessManager");
        address configurator = _addr(cfg, ".aave.spokeConfigurator");
        address guardian = _addr(cfg, ".governance.aaveProtocolGuardian");
        uint64 role = uint64(vm.parseJsonUint(cfg, ".aavePayload.guardianRole"));
        // Outside Aave V4's role ranges (0-499, aave-v4 Roles.sol) and apart from Avana's loss-layer roles.
        require(
            role >= 500 && role != vm.parseJsonUint(cfg, ".aavePayload.lossLayerRoles.coverageRole")
                && role != vm.parseJsonUint(cfg, ".aavePayload.lossLayerRoles.reserveAdminRole")
                && role != vm.parseJsonUint(cfg, ".aavePayload.lossLayerRoles.withdrawRole"),
            "aavePayload.guardianRole: outside 0-499 and not a loss-layer role"
        );
        IGuardianAccessViews v = IGuardianAccessViews(am);
        if (!v.isRoleLabeled(role)) {
            _roleUpdate(
                b,
                ARoleUpdate({
                    authority: am,
                    roleId: role,
                    admin: AFlags.KEEP_CURRENT_UINT64,
                    guardian: AFlags.KEEP_CURRENT_UINT64,
                    grantDelay: AFlags.KEEP_CURRENT_UINT32,
                    label: AaveGuardianRole.LABEL,
                    labelUpdate: false
                })
            );
        }
        bytes4[] memory sel = AaveGuardianRole.selectors();
        if (
            v.getTargetFunctionRole(configurator, sel[0]) != role
                || v.getTargetFunctionRole(configurator, sel[1]) != role
        ) {
            _targetFunctionRole(b, ATargetFunctionRoleUpdate(am, configurator, sel, role));
        }
        address[2] memory holders = [guardian, executor];
        for (uint256 i = 0; i < holders.length; ++i) {
            (bool member,) = v.hasRole(role, holders[i]);
            if (!member) _roleMembership(b, ARoleMembership(am, role, holders[i], true, 0));
        }
    }

    /// @notice The debt assets on one Hub: the asset listing, its rate curve, the treasury as fee receiver.
    function _hubAssets(
        Builder memory b,
        uint256 h
    ) private view {
        string memory label = vm.parseJsonString(cfg, string.concat(_hk(h), ".label"));
        uint256 nAssets = _count(cfg, ".aavePayload.debtAssets");
        for (uint256 i = 0; i < nAssets; ++i) {
            address token = _addr(cfg, string.concat(_ak(i), ".token"));
            if (!_assetOnHub(cfg, i, label) || IAaveListedViews(_hub(label)).isUnderlyingListed(token)) continue;
            AAssetListing memory l;
            l.hubConfigurator = _addr(cfg, ".aave.hubConfigurator");
            l.hub = _hub(label);
            l.underlying = token;
            l.feeReceiver = _addr(cfg, ".aave.treasurySpoke");
            l.liquidityFee = _liquidityFee(i, label);
            l.irStrategy = _addr(cfg, string.concat(".aave.irStrategies.", label));
            l.irData = _rateModel(i, label);
            _assetListing(b, l);
        }
    }

    /// @notice The asset's liquidity fee (its reserve factor, bps) on Hub `label`:
    /// `.aavePayload.debtAssets[i].liquidityFeeByHub.<label>`, else its `.liquidityFeeBps`, else 0. Applied when the
    /// asset is listed on the Hub.
    function _liquidityFee(
        uint256 i,
        string memory label
    ) private view returns (uint256) {
        string memory k = string.concat(_ak(i), ".liquidityFeeByHub.", label);
        if (vm.keyExistsJson(cfg, k)) return vm.parseJsonUint(cfg, k);
        k = string.concat(_ak(i), ".liquidityFeeBps");
        return vm.keyExistsJson(cfg, k) ? vm.parseJsonUint(cfg, k) : 0;
    }

    /// @notice The asset's rate curve on Hub `label`, in bps: `.aavePayload.debtAssets[i].rateModelByHub.<label>`, else
    /// its `.rateModel`, else 90 % optimal usage, 0 base, 4 % and 60 % growth. Applied when the asset is listed on the
    /// Hub; an asset listed earlier keeps its curve (a change is an 11-changes rate change).
    function _rateModel(
        uint256 i,
        string memory label
    ) private view returns (AInterestRateData memory) {
        string memory k = string.concat(_ak(i), ".rateModelByHub.", label);
        if (!vm.keyExistsJson(cfg, k)) k = string.concat(_ak(i), ".rateModel");
        if (!vm.keyExistsJson(cfg, k)) return AInterestRateData(9000, 0, 400, 6000);
        return AInterestRateData(
            uint16(vm.parseJsonUint(cfg, string.concat(k, ".optimalUsageBps"))),
            uint32(vm.parseJsonUint(cfg, string.concat(k, ".baseDrawnRateBps"))),
            uint32(vm.parseJsonUint(cfg, string.concat(k, ".rateGrowthBeforeOptimalBps"))),
            uint32(vm.parseJsonUint(cfg, string.concat(k, ".rateGrowthAfterOptimalBps")))
        );
    }

    /// @notice The Lend Spoke and the CDP Spokes of one Hub on every debt asset, their reserves and the CDP liquidation
    /// configuration.
    function _hubSpokes(
        Builder memory b,
        uint256 h
    ) private view {
        string memory hk = _hk(h);
        string memory label = vm.parseJsonString(cfg, string.concat(hk, ".label"));
        address hub = _hub(label);
        uint40 maxCap = IAaveHubLimits(hub).MAX_ALLOWED_SPOKE_CAP();
        uint24 maxRp = IAaveHubLimits(hub).MAX_RISK_PREMIUM_THRESHOLD();
        _spokeOnAssets(
            b, label, hub, _spoke(vm.parseJsonString(cfg, string.concat(hk, ".lendSpoke"))), maxCap, false, maxRp
        );
        string[] memory cdps = vm.parseJsonStringArray(cfg, string.concat(hk, ".cdpSpokes"));
        for (uint256 s = 0; s < cdps.length; ++s) {
            // A CDP Spoke new to this Hub also gets its liquidation configuration.
            if (!_spokeOnAssets(b, label, hub, _spoke(cdps[s]), 0, true, maxRp)) continue;
            ALiquidationConfigUpdate memory lc;
            lc.spokeConfigurator = _addr(cfg, ".aave.spokeConfigurator");
            lc.spoke = _spoke(cdps[s]);
            (lc.targetHealthFactor, lc.healthFactorForMaxBonus, lc.liquidationBonusFactor) = (1.1e18, 0.95e18, 5000);
            _liquidationConfigUpdate(b, lc);
        }
    }

    /// @notice One Spoke on every debt asset of its Hub: supply-only at `addCap` (Lend) or draw-only at the asset's draw
    /// cap (CDP), and its reserve on each asset (a CDP debt reserve not borrowable yet, collateral factor 0).
    /// @return isNew Whether the Spoke was on none of this Hub's assets before.
    function _spokeOnAssets(
        Builder memory b,
        string memory label,
        address hub,
        address spoke,
        uint40 addCap,
        bool cdp,
        uint24 maxRp
    ) private view returns (bool isNew) {
        uint256 nAssets = _count(cfg, ".aavePayload.debtAssets");
        ASpokeToAssetsAddition memory add;
        add.hubConfigurator = _addr(cfg, ".aave.hubConfigurator");
        add.hub = hub;
        add.spoke = spoke;
        add.assets = new ASpokeAssetConfig[](nAssets);
        uint256 added;
        isNew = true;
        for (uint256 i = 0; i < nAssets; ++i) {
            if (!_assetOnHub(cfg, i, label) || (cdp && _assetLendOnly(cfg, i))) continue;
            address token = _addr(cfg, string.concat(_ak(i), ".token"));
            if (_spokeOn(hub, token, spoke)) {
                isNew = false;
                continue;
            }
            uint40 drawCap = cdp ? uint40(vm.parseJsonUint(cfg, string.concat(_ak(i), ".drawCap"))) : 0;
            add.assets[added++] = ASpokeAssetConfig(token, ASpokeConfig(addCap, drawCap, maxRp, true, false));
            AReserveListing memory r;
            r.spokeConfigurator = _addr(cfg, ".aave.spokeConfigurator");
            r.spoke = spoke;
            r.hub = hub;
            r.underlying = token;
            r.priceSource = _addr(cfg, string.concat(_ak(i), ".priceSource"));
            r.config = AReserveConfig(0, false, false, !cdp, false);
            r.dynamicConfig = ADynamicReserveConfig(0, 10_000, 0);
            _reserveListing(b, r);
        }
        if (added == 0) return false;
        ASpokeAssetConfig[] memory assets = add.assets;
        assembly ("memory-safe") {
            mstore(assets, added)
        }
        _spokeToAssets(b, add);
    }

    /// @notice The treasury's bootstrap supply of each Lend Spoke: the test-network faucet mints to the executor, which
    /// supplies as the Collector does on Ethereum.
    function _bootstrap() private returns (Builder memory b) {
        b = _newBuilder();
        uint256 nHubs = _count(cfg, ".aavePayload.hubs");
        uint256 nAssets = _count(cfg, ".aavePayload.debtAssets");
        address minter = _addr(cfg, ".aavePayload.tokenMinter");
        for (uint256 h = 0; h < nHubs; ++h) {
            address hub = _hub(vm.parseJsonString(cfg, string.concat(_hk(h), ".label")));
            address lend = _spoke(vm.parseJsonString(cfg, string.concat(_hk(h), ".lendSpoke")));
            for (uint256 i = 0; i < nAssets; ++i) {
                address token = _addr(cfg, string.concat(_ak(i), ".token"));
                uint256 amount = vm.parseJsonUint(cfg, string.concat(_ak(i), ".bootstrapSupply"));
                if (amount == 0 || !_assetOnHub(cfg, i, vm.parseJsonString(cfg, string.concat(_hk(h), ".label")))) {
                    continue;
                }
                uint256 reserveId = ILendSpoke(lend).getReserveId(hub, IAaveHubLimits(hub).getAssetId(token));
                // Supplied once, by the first run that finds the reserve listed.
                if (ILendSpoke(lend).getUserSuppliedAssets(reserveId, executor) != 0) continue;
                vm.broadcast(minter);
                ITestTokenMint(token).mint(executor, amount);
                _postCall(b, token, abi.encodeCall(ITestTokenMint.approve, (lend, amount)));
                _postCall(b, lend, abi.encodeCall(ILendSpoke.supply, (reserveId, amount, executor)));
            }
        }
    }

    function _flashBorrowers() private view returns (Builder memory b) {
        b = _newBuilder();
        string memory avana = vm.readFile(_outputPath("avana"));
        address acl = _addr(cfg, ".aavePayload.flashAcl");
        address[2] memory borrowers =
            [vm.parseJsonAddress(avana, ".flashSource"), vm.parseJsonAddress(avana, ".flashLiquidator")];
        for (uint256 i = 0; i < 2; ++i) {
            if (IFlashAcl(acl).isFlashBorrower(borrowers[i])) continue;
            _postCall(b, acl, abi.encodeCall(IFlashAcl.addFlashBorrower, (borrowers[i])));
        }
    }
}
