// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/dependencies/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/dependencies/aave/IAaveV4Spoke.sol";
import {AaveCalls} from "./lib/AaveCalls.sol";
import {CoreStack} from "./lib/DeployTypes.sol";

/// @notice The Aave V4 configurator calls and views of the markets AIP (aave-v4 a3ef63e).
interface IAaveMarketsConfig {
    struct SpokeConfig {
        uint40 addCap;
        uint40 drawCap;
        uint24 riskPremiumThreshold;
        bool active;
        bool halted;
    }

    struct ReserveConfig {
        uint24 collateralRisk;
        bool paused;
        bool frozen;
        bool borrowable;
        bool receiveSharesEnabled;
    }

    struct DynamicReserveConfig {
        uint16 collateralFactor;
        uint32 maxLiquidationBonus;
        uint16 liquidationFee;
    }

    struct InterestRateData {
        uint16 optimalUsageRatio;
        uint32 baseDrawnRate;
        uint32 rateGrowthBeforeOptimal;
        uint32 rateGrowthAfterOptimal;
    }

    function addAssetWithDecimals(
        address hub,
        address underlying,
        uint8 decimals,
        address feeReceiver,
        uint256 liquidityFee,
        address irStrategy,
        bytes calldata irData
    ) external returns (uint256);

    function addSpoke(
        address hub,
        address spoke,
        uint256 assetId,
        SpokeConfig calldata config
    ) external;

    function addReserve(
        address spoke,
        address hub,
        uint256 assetId,
        address priceSource,
        ReserveConfig calldata config,
        DynamicReserveConfig calldata dynamicConfig
    ) external returns (uint256);

    function updateBorrowable(
        address spoke,
        uint256 reserveId,
        bool borrowable
    ) external;

    function updatePositionManager(
        address spoke,
        address positionManager,
        bool active
    ) external;

    function getAssetCount() external view returns (uint256);

    function isPositionManagerActive(
        address positionManager
    ) external view returns (bool);
}

/// @title AaveListingPayload
/// @notice Step 10, the Aave-side AIP `AvanaMarkets`:
/// - each integration's AaveAdapter approved as a position manager on each of its CDP Spokes (`listing.spokes`);
/// - each debt reserve of `listing.debtReserves` made borrowable (06 lists them not borrowable);
/// - each market of `markets.json` (`09_ListMarkets`, `vault-tokens`): its vault token listed on the Hub with the
///   token's decimals, on its CDP Spoke with the market's `addCap` in whole tokens (`marketUsdCap`; a whole token was
///   worth at least $1 at listing) and no draw, and a collateral reserve priced by the market's LPOracle: collateral
///   factor the market's LTV, liquidation fee 0, not borrowable, no share transfers, as `RiskModule.activateMarket`
///   checks.
/// @dev A Hub numbers its assets consecutively, so the AIP plans each new vault token's asset id from `getAssetCount`.
/// Only what is not on chain yet; a rerun with nothing new proposes nothing.
contract AaveListingPayload is AaveCalls {
    string internal cfg;

    /// @dev New assets planned per Hub in this AIP.
    address[] internal plannedHubs;
    uint256[] internal plannedCounts;

    function run() external {
        cfg = vm.readFile(_configPath(_network()));
        (address executor, address controller) = _executorOf(cfg);
        Calls memory k = _newCalls("AvanaMarkets");
        _positionManagers(k);
        _borrowable(k);
        _markets(k);
        _ship(k, executor, controller);
    }

    function _configurator() private view returns (address) {
        return _addr(cfg, ".aave.spokeConfigurator");
    }

    function _positionManagers(
        Calls memory k
    ) private view {
        uint256 n = _count(cfg, ".listing.spokes");
        for (uint256 i = 0; i < n; ++i) {
            string memory sk = string.concat(".listing.spokes[", vm.toString(i), "]");
            CoreStack memory s = _stackOf(uint32(vm.parseJsonUint(cfg, string.concat(sk, ".integrationId"))));
            address spoke = _addr(cfg, string.concat(sk, ".spoke"));
            if (IAaveMarketsConfig(spoke).isPositionManagerActive(s.aaveAdapter)) continue;
            _call(
                k,
                _configurator(),
                abi.encodeCall(IAaveMarketsConfig.updatePositionManager, (spoke, s.aaveAdapter, true)),
                string.concat("AaveAdapter position manager on ", vm.parseJsonString(cfg, string.concat(sk, ".label")))
            );
        }
    }

    function _borrowable(
        Calls memory k
    ) private view {
        uint256 n = _count(cfg, ".listing.debtReserves");
        for (uint256 i = 0; i < n; ++i) {
            string memory dk = string.concat(".listing.debtReserves[", vm.toString(i), "]");
            string memory label = vm.parseJsonString(cfg, string.concat(dk, ".spoke"));
            (address spoke, address hub) = _spokeAndHub(label);
            address asset = _debtAsset(vm.parseJsonString(cfg, string.concat(dk, ".symbol")));
            uint256 reserveId = IAaveV4Spoke(spoke).getReserveId(hub, IAaveV4Hub(hub).getAssetId(asset));
            if (IAaveV4Spoke(spoke).getReserveConfig(reserveId).borrowable) continue;
            _call(
                k,
                _configurator(),
                abi.encodeCall(IAaveMarketsConfig.updateBorrowable, (spoke, reserveId, true)),
                string.concat("borrowable: ", vm.parseJsonString(cfg, string.concat(dk, ".symbol")), " on ", label)
            );
        }
    }

    /// @dev One row of `markets.json`.
    struct Row {
        string id;
        address token;
        address oracle;
        address spoke;
        address hub;
        uint8 decimals;
        uint16 ltvBps;
        uint32 maxLiquidationBonus;
        uint40 addCap;
    }

    function _markets(
        Calls memory k
    ) private {
        string memory path = _outputPath("markets");
        require(vm.exists(path), "no markets.json: run 09-vault-tokens first");
        string memory json = vm.readFile(path);
        uint256 n = vm.parseJsonUintArray(json, ".marketIds").length;
        for (uint256 i = 0; i < n; ++i) {
            Row memory r = _row(json, i);
            if (IAaveV4Hub(r.hub).isUnderlyingListed(r.token)) continue;
            _listMarket(k, r, _nextAssetId(r.hub));
        }
    }

    function _row(
        string memory json,
        uint256 i
    ) private pure returns (Row memory r) {
        r.id = vm.toString(vm.parseJsonUintArray(json, ".marketIds")[i]);
        r.token = vm.parseJsonAddressArray(json, ".vaultTokens")[i];
        r.oracle = vm.parseJsonAddressArray(json, ".lpOracles")[i];
        r.spoke = vm.parseJsonAddressArray(json, ".spokes")[i];
        r.hub = vm.parseJsonAddressArray(json, ".hubs")[i];
        r.decimals = uint8(vm.parseJsonUintArray(json, ".unitDecimals")[i]);
        r.ltvBps = uint16(vm.parseJsonUintArray(json, ".ltvBps")[i]);
        r.maxLiquidationBonus = uint32(vm.parseJsonUintArray(json, ".maxLiquidationBonus")[i]);
        r.addCap = uint40(vm.parseJsonUintArray(json, ".addCaps")[i]);
    }

    function _listMarket(
        Calls memory k,
        Row memory r,
        uint256 assetId
    ) private view {
        address hubConfigurator = _addr(cfg, ".aave.hubConfigurator");
        bytes memory irData = abi.encode(IAaveMarketsConfig.InterestRateData(9000, 0, 400, 6000));
        _call(
            k,
            hubConfigurator,
            abi.encodeCall(
                IAaveMarketsConfig.addAssetWithDecimals,
                (r.hub, r.token, r.decimals, _addr(cfg, ".aave.treasurySpoke"), 0, _irStrategy(r.hub), irData)
            ),
            string.concat("market ", r.id, ": vault token as a Hub asset")
        );
        IAaveMarketsConfig.SpokeConfig memory sc =
            IAaveMarketsConfig.SpokeConfig(r.addCap, 0, IAaveV4Hub(r.hub).MAX_RISK_PREMIUM_THRESHOLD(), true, false);
        _call(
            k,
            hubConfigurator,
            abi.encodeCall(IAaveMarketsConfig.addSpoke, (r.hub, r.spoke, assetId, sc)),
            string.concat("market ", r.id, ": CDP Spoke on the asset, no draw")
        );
        _call(
            k,
            _configurator(),
            abi.encodeCall(
                IAaveMarketsConfig.addReserve,
                (
                    r.spoke,
                    r.hub,
                    assetId,
                    r.oracle,
                    IAaveMarketsConfig.ReserveConfig(0, false, false, false, false),
                    IAaveMarketsConfig.DynamicReserveConfig(r.ltvBps, r.maxLiquidationBonus, 0)
                )
            ),
            string.concat("market ", r.id, ": collateral reserve priced by its LPOracle")
        );
    }

    /// @notice The id the Hub gives its next new asset in this AIP.
    function _nextAssetId(
        address hub
    ) private returns (uint256 id) {
        for (uint256 i = 0; i < plannedHubs.length; ++i) {
            if (plannedHubs[i] == hub) return IAaveMarketsConfig(hub).getAssetCount() + plannedCounts[i]++;
        }
        plannedHubs.push(hub);
        plannedCounts.push(1);
        return IAaveMarketsConfig(hub).getAssetCount();
    }

    /// @notice The rate strategy of `hub`: `aave.irStrategies.<label>` of its `aave.hubs` label.
    function _irStrategy(
        address hub
    ) private view returns (address) {
        uint256 n = _count(cfg, ".aave.hubs");
        for (uint256 i = 0; i < n; ++i) {
            string memory hk = string.concat(".aave.hubs[", vm.toString(i), "]");
            if (_addr(cfg, string.concat(hk, ".hub")) != hub) continue;
            return
                _addr(cfg, string.concat(".aave.irStrategies.", vm.parseJsonString(cfg, string.concat(hk, ".label"))));
        }
        revert(string.concat("no aave.hubs entry for ", vm.toString(hub)));
    }

    function _spokeAndHub(
        string memory label
    ) private view returns (address spoke, address hub) {
        uint256 n = _count(cfg, ".listing.spokes");
        for (uint256 i = 0; i < n; ++i) {
            string memory sk = string.concat(".listing.spokes[", vm.toString(i), "]");
            if (!_eq(vm.parseJsonString(cfg, string.concat(sk, ".label")), label)) continue;
            return
                (
                    _addr(cfg, string.concat(sk, ".spoke")),
                    _hubOf(cfg, vm.parseJsonString(cfg, string.concat(sk, ".hub")))
                );
        }
        revert(string.concat("no listing.spokes entry ", label));
    }

    function _debtAsset(
        string memory symbol
    ) private view returns (address) {
        uint256 n = _count(cfg, ".listing.debtAssets");
        for (uint256 i = 0; i < n; ++i) {
            string memory dk = string.concat(".listing.debtAssets[", vm.toString(i), "]");
            if (_eq(vm.parseJsonString(cfg, string.concat(dk, ".symbol")), symbol)) {
                return _addr(cfg, string.concat(dk, ".address"));
            }
        }
        revert(string.concat("no listing.debtAssets entry ", symbol));
    }
}
