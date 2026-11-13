// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AAssetListing, ADynamicReserveConfig, AInterestRateData, ALiquidationConfigUpdate, AReserveConfig, AReserveListing, ASpokeAssetConfig, ASpokeConfig, ASpokeToAssetsAddition, IAaveHubLimits, AavePayloads} from "./lib/AavePayloads.sol";

interface IFlashAcl {
    function addFlashBorrower(
        address borrower
    ) external;
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
/// test networks it deploys and executes them as the PayloadsController stand-in. Coverage Spokes and the DAO
/// deficit offsets are registered by their own AIP (`08_AaveLossLayersPayload`) once they are deployed.
contract AaveDeploymentPayload is AavePayloads {
    string internal cfg;
    address internal executor;
    address internal controller;
    address internal engine;
    bool internal execute;

    function run() external {
        cfg = vm.readFile(string.concat(vm.projectRoot(), "/script/deploy/config/", _network(), ".json"));
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
            if (_eq(vm.parseJsonString(cfg, string.concat(k, ".label")), label)) return _addr(cfg, string.concat(k, ".hub"));
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

    function _deployment() private view returns (Builder memory b) {
        b = _newBuilder();
        uint256 nHubs = _count(cfg, ".aavePayload.hubs");
        for (uint256 h = 0; h < nHubs; ++h) {
            _hubAssets(b, h);
            _hubSpokes(b, h);
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
            AAssetListing memory l;
            l.hubConfigurator = _addr(cfg, ".aave.hubConfigurator");
            l.hub = _hub(label);
            l.underlying = _addr(cfg, string.concat(_ak(i), ".token"));
            l.feeReceiver = _addr(cfg, ".aave.treasurySpoke");
            l.liquidityFee = 0;
            l.irStrategy = _addr(cfg, string.concat(".aave.irStrategies.", label));
            l.irData = AInterestRateData(9000, 0, 400, 6000);
            _assetListing(b, l);
        }
    }

    /// @notice The Lend Spoke and the CDP Spokes of one Hub on every debt asset, their reserves and the CDP liquidation
    /// configuration.
    function _hubSpokes(
        Builder memory b,
        uint256 h
    ) private view {
        string memory hk = _hk(h);
        address hub = _hub(vm.parseJsonString(cfg, string.concat(hk, ".label")));
        uint40 maxCap = IAaveHubLimits(hub).MAX_ALLOWED_SPOKE_CAP();
        uint24 maxRp = IAaveHubLimits(hub).MAX_RISK_PREMIUM_THRESHOLD();
        _spokeOnAssets(b, hub, _spoke(vm.parseJsonString(cfg, string.concat(hk, ".lendSpoke"))), maxCap, false, maxRp);
        string[] memory cdps = vm.parseJsonStringArray(cfg, string.concat(hk, ".cdpSpokes"));
        for (uint256 s = 0; s < cdps.length; ++s) {
            _spokeOnAssets(b, hub, _spoke(cdps[s]), 0, true, maxRp);
            ALiquidationConfigUpdate memory lc;
            lc.spokeConfigurator = _addr(cfg, ".aave.spokeConfigurator");
            lc.spoke = _spoke(cdps[s]);
            (lc.targetHealthFactor, lc.healthFactorForMaxBonus, lc.liquidationBonusFactor) = (1.1e18, 0.95e18, 5000);
            _liquidationConfigUpdate(b, lc);
        }
    }

    /// @notice One Spoke on every debt asset of its Hub: supply-only at `addCap` (Lend) or draw-only at the asset's draw
    /// cap (CDP), and its reserve on each asset (a CDP debt reserve not borrowable yet, collateral factor 0).
    function _spokeOnAssets(
        Builder memory b,
        address hub,
        address spoke,
        uint40 addCap,
        bool cdp,
        uint24 maxRp
    ) private view {
        uint256 nAssets = _count(cfg, ".aavePayload.debtAssets");
        ASpokeToAssetsAddition memory add;
        add.hubConfigurator = _addr(cfg, ".aave.hubConfigurator");
        add.hub = hub;
        add.spoke = spoke;
        add.assets = new ASpokeAssetConfig[](nAssets);
        for (uint256 i = 0; i < nAssets; ++i) {
            address token = _addr(cfg, string.concat(_ak(i), ".token"));
            uint40 drawCap = cdp ? uint40(vm.parseJsonUint(cfg, string.concat(_ak(i), ".drawCap"))) : 0;
            add.assets[i] =
                ASpokeAssetConfig(token, ASpokeConfig(addCap, drawCap, maxRp, true, false));
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
                if (amount == 0) continue;
                vm.broadcast(minter);
                ITestTokenMint(token).mint(executor, amount);
                uint256 reserveId = ILendSpoke(lend).getReserveId(hub, IAaveHubLimits(hub).getAssetId(token));
                _postCall(b, token, abi.encodeCall(ITestTokenMint.approve, (lend, amount)));
                _postCall(b, lend, abi.encodeCall(ILendSpoke.supply, (reserveId, amount, executor)));
            }
        }
    }

    function _flashBorrowers() private view returns (Builder memory b) {
        b = _newBuilder();
        string memory avana = vm.readFile(_outputPath("avana"));
        address acl = _addr(cfg, ".aavePayload.flashAcl");
        _postCall(b, acl, abi.encodeCall(IFlashAcl.addFlashBorrower, (vm.parseJsonAddress(avana, ".flashSource"))));
        _postCall(b, acl, abi.encodeCall(IFlashAcl.addFlashBorrower, (vm.parseJsonAddress(avana, ".flashLiquidator"))));
    }
}
