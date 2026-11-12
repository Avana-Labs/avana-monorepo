// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DeployBase} from "./lib/DeployBase.sol";
import {console2} from "forge-std/console2.sol";

/// @dev Aave V4 a3ef63e configurator structs (as in `test/utils/fixtures/CollateralizationFixture.sol`).
struct HubSpokeConfig {
    uint40 addCap;
    uint40 drawCap;
    uint24 riskPremiumThreshold;
    bool active;
    bool halted;
}

struct SpokeReserveConfig {
    uint24 collateralRisk;
    bool paused;
    bool frozen;
    bool borrowable;
    bool receiveSharesEnabled;
}

struct SpokeDynamicReserveConfig {
    uint16 collateralFactor;
    uint32 maxLiquidationBonus;
    uint16 liquidationFee;
}

struct SpokeLiquidationConfig {
    uint128 targetHealthFactor;
    uint64 healthFactorForMaxBonus;
    uint16 liquidationBonusFactor;
}

struct InterestRateData {
    uint16 optimalUsageRatio;
    uint32 baseDrawnRate;
    uint32 rateGrowthBeforeOptimal;
    uint32 rateGrowthAfterOptimal;
}

interface IHubConfigurator {
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
        HubSpokeConfig calldata config
    ) external;
}

interface ISpokeConfigurator {
    function addReserve(
        address spoke,
        address hub,
        uint256 assetId,
        address priceSource,
        SpokeReserveConfig calldata config,
        SpokeDynamicReserveConfig calldata dynamicConfig
    ) external returns (uint256);
    function updateLiquidationConfig(
        address spoke,
        SpokeLiquidationConfig calldata config
    ) external;
}

interface IHubView {
    function MAX_ALLOWED_SPOKE_CAP() external view returns (uint40);
    function MAX_RISK_PREMIUM_THRESHOLD() external view returns (uint24);
    function getAssetId(
        address underlying
    ) external view returns (uint256);
}

interface IAccessManagerGrant {
    function grantRole(
        uint64 role,
        address account,
        uint32 executionDelay
    ) external;
}

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
/// @notice The Aave-side half of an Avana deployment (governance README, "Deployment AIP (per chain)"): for every Hub
/// and every debt asset of `aavePayload.debtAssets`, the Hub asset with its kinked rate curve, the Lend Spoke listing
/// open to lenders, the CDP Spokes of that Hub registered with their draw caps and the debt reserve listed before any
/// vault-token reserve, the CDP Spoke liquidation configuration (target health factor 1.10, the bonus curve), the
/// Avana Umbrella (Coverage Spoke) of each (Hub, asset), registered supply-only and given
/// `HUB_DEFICIT_ELIMINATOR_ROLE`, and `FLASH_BORROWER` on the Aave V3 ACL for the flash source and the public flash
/// liquidation helper; plus, on test networks, the bootstrap supply of each Lend Spoke from the DAO treasury.
/// @dev On Ethereum and Base this is a draft: it only writes `deployments-local/<network>/aave-payload.json`, the calls the
/// AIP must contain, for `governance/operations/<date>_<Chain>_AvanaDeploymentAip/`. On anvil and Tenderly it runs them
/// as the network's Aave DAO account (`--unlocked`), deploying each Coverage Spoke between the asset listing and its
/// registration (the Coverage Spoke constructor reads the Hub's asset ID). Price sources of the debt reserves come from
/// the config: a fixed $1 source for GHO and the asset's feed until its DebtOracle is listed (`MKT-065` pairs the
/// switch with the Avana operation).
contract AaveDeploymentPayload is DeployBase {
    /// @notice Aave Hub role of a Coverage Spoke (`Roles.HUB_DEFICIT_ELIMINATOR_ROLE`).
    uint64 internal constant HUB_DEFICIT_ELIMINATOR_ROLE = 103;

    string internal cfg;
    string internal aaveJson;
    address internal dao;
    bool internal execute;
    string internal calls;
    string internal coverage;
    uint256 internal callCount;

    function run() external {
        string memory network = _network();
        cfg = vm.readFile(string.concat(vm.projectRoot(), "/script/deploy/config/", network, ".json"));
        aaveJson = vm.readFile(_outputPath("aave"));
        dao = _addr(cfg, ".aaveLocal.aaveDao");
        execute = block.chainid != 1 && block.chainid != 8453;
        string memory avana = vm.readFile(_outputPath("avana"));

        if (execute) vm.startBroadcast(dao);
        uint256 nAssets = _count(cfg, ".aavePayload.debtAssets");
        uint256 nHubs = _count(cfg, ".aavePayload.hubs");
        for (uint256 h = 0; h < nHubs; ++h) {
            string memory hk = string.concat(".aavePayload.hubs[", vm.toString(h), "]");
            for (uint256 i = 0; i < nAssets; ++i) {
                _listDebtAsset(hk, string.concat(".aavePayload.debtAssets[", vm.toString(i), "]"));
            }
            _liquidationConfigs(hk);
        }
        address acl = _addr(cfg, ".aavePayload.flashAcl");
        _call(
            acl,
            abi.encodeCall(IFlashAcl.addFlashBorrower, (vm.parseJsonAddress(avana, ".flashSource"))),
            "FLASH_BORROWER flash source"
        );
        _call(
            acl,
            abi.encodeCall(IFlashAcl.addFlashBorrower, (vm.parseJsonAddress(avana, ".flashLiquidator"))),
            "FLASH_BORROWER FlashLiquidator"
        );
        if (execute) vm.stopBroadcast();
        vm.writeJson(calls, _outputPath("aave-payload"));
        if (bytes(coverage).length != 0) vm.writeJson(coverage, _outputPath("coverage"));
        console2.log(execute ? "executed as the Aave DAO account:" : "draft written:", callCount, "calls");
    }

    /// @notice What every call of one (Hub, debt asset) listing needs.
    struct Listing {
        string hk;
        string ak;
        string hubLabel;
        address hub;
        address token;
        address source;
        uint256 assetId;
        uint40 maxCap;
        uint24 maxRp;
        address hubCfg;
        address spokeCfg;
    }

    /// @notice One debt asset on one Hub: asset, Lend Spoke, CDP Spokes, reserves, Coverage Spoke, bootstrap supply.
    function _listDebtAsset(
        string memory hk,
        string memory ak
    ) private {
        Listing memory l;
        (l.hk, l.ak) = (hk, ak);
        l.hubLabel = vm.parseJsonString(cfg, string.concat(hk, ".label"));
        l.hub = vm.parseJsonAddress(aaveJson, string.concat(".hubs.", l.hubLabel, ".proxy"));
        l.token = _addr(cfg, string.concat(ak, ".token"));
        l.source = _addr(cfg, string.concat(ak, ".priceSource"));
        l.maxCap = IHubView(l.hub).MAX_ALLOWED_SPOKE_CAP();
        l.maxRp = IHubView(l.hub).MAX_RISK_PREMIUM_THRESHOLD();
        l.hubCfg = vm.parseJsonAddress(aaveJson, ".hubConfigurator");
        l.spokeCfg = vm.parseJsonAddress(aaveJson, ".spokeConfigurator");
        _addAsset(l);
        // Asset IDs are only known once the asset is added; a draft (Ethereum, Base) leaves 0 for the AIP author.
        l.assetId = execute ? IHubView(l.hub).getAssetId(l.token) : 0;
        // Lend Spoke: open to lenders up to the supply cap, no draw.
        address lend = _spoke(vm.parseJsonString(cfg, string.concat(hk, ".lendSpoke")));
        _addSpokeWithReserve(l, lend, HubSpokeConfig(l.maxCap, 0, l.maxRp, true, false), "Lend");
        // CDP Spokes of this Hub: draw caps within the credit line; debt reserve with collateral factor 0.
        string[] memory cdps = vm.parseJsonStringArray(cfg, string.concat(hk, ".cdpSpokes"));
        uint40 drawCap = uint40(vm.parseJsonUint(cfg, string.concat(ak, ".drawCap")));
        for (uint256 s = 0; s < cdps.length; ++s) {
            _addSpokeWithReserve(l, _spoke(cdps[s]), HubSpokeConfig(0, drawCap, l.maxRp, true, false), "CDP debt");
        }
        if (execute) {
            _coverageSpoke(l);
            _bootstrapSupply(
                lend, l.hub, l.assetId, l.token, vm.parseJsonUint(cfg, string.concat(ak, ".bootstrapSupply"))
            );
        }
    }

    function _addAsset(
        Listing memory l
    ) private {
        bytes memory ir = abi.encode(InterestRateData(9000, 0, 400, 6000));
        address irStrategy = vm.parseJsonAddress(aaveJson, string.concat(".hubs.", l.hubLabel, ".irStrategy"));
        uint8 decimals = uint8(vm.parseJsonUint(cfg, string.concat(l.ak, ".decimals")));
        address treasury = vm.parseJsonAddress(aaveJson, ".treasurySpoke");
        _call(
            l.hubCfg,
            abi.encodeCall(
                IHubConfigurator.addAssetWithDecimals, (l.hub, l.token, decimals, treasury, 0, irStrategy, ir)
            ),
            "HubConfigurator.addAssetWithDecimals"
        );
    }

    function _addSpokeWithReserve(
        Listing memory l,
        address spoke,
        HubSpokeConfig memory hubConfig,
        string memory label
    ) private {
        _call(
            l.hubCfg,
            abi.encodeCall(IHubConfigurator.addSpoke, (l.hub, spoke, l.assetId, hubConfig)),
            string.concat("addSpoke ", label)
        );
        _call(
            l.spokeCfg,
            abi.encodeCall(
                ISpokeConfigurator.addReserve,
                (
                    spoke,
                    l.hub,
                    l.assetId,
                    l.source,
                    SpokeReserveConfig(0, false, false, true, false),
                    SpokeDynamicReserveConfig(0, 10_000, 0)
                )
            ),
            string.concat("addReserve ", label)
        );
    }

    /// @notice Avana Umbrella: Avana deploys it (step 12), the DAO registers it supply-only and grants the deficit role.
    function _coverageSpoke(
        Listing memory l
    ) private {
        address am = vm.parseJsonAddress(aaveJson, ".accessManager");
        string memory name =
            string.concat("CoverageSpoke.", l.hubLabel, ".", vm.parseJsonString(cfg, string.concat(l.ak, ".symbol")));
        address cs = _deploy(
            name,
            bytes.concat(
                _artifact("CoverageSpoke.sol", "CoverageSpoke"),
                abi.encode(l.hub, l.token, l.assetId, am, uint256(1_209_600))
            )
        );
        _call(
            l.hubCfg,
            abi.encodeCall(
                IHubConfigurator.addSpoke, (l.hub, cs, l.assetId, HubSpokeConfig(l.maxCap, 0, l.maxRp, true, false))
            ),
            "addSpoke Coverage"
        );
        _call(
            am,
            abi.encodeCall(IAccessManagerGrant.grantRole, (HUB_DEFICIT_ELIMINATOR_ROLE, cs, 0)),
            "grant HUB_DEFICIT_ELIMINATOR_ROLE"
        );
        coverage = vm.serializeAddress("coverage", name, cs);
    }

    function _liquidationConfigs(
        string memory hk
    ) private {
        string[] memory cdps = vm.parseJsonStringArray(cfg, string.concat(hk, ".cdpSpokes"));
        for (uint256 s = 0; s < cdps.length; ++s) {
            _call(
                vm.parseJsonAddress(aaveJson, ".spokeConfigurator"),
                abi.encodeCall(
                    ISpokeConfigurator.updateLiquidationConfig,
                    (_spoke(cdps[s]), SpokeLiquidationConfig(1.1e18, 0.95e18, 5000))
                ),
                "updateLiquidationConfig"
            );
        }
    }

    /// @notice The DAO treasury's bootstrap supply on the Lend Spoke (test networks: minted to the DAO account).
    function _bootstrapSupply(
        address lend,
        address hub,
        uint256 assetId,
        address token,
        uint256 amount
    ) private {
        if (amount == 0) return;
        vm.stopBroadcast();
        vm.broadcast(_addr(cfg, ".aavePayload.tokenMinter"));
        ITestTokenMint(token).mint(dao, amount);
        vm.startBroadcast(dao);
        ITestTokenMint(token).approve(lend, amount);
        ILendSpoke(lend).supply(ILendSpoke(lend).getReserveId(hub, assetId), amount, dao);
    }

    function _spoke(
        string memory label
    ) private view returns (address) {
        return vm.parseJsonAddress(aaveJson, string.concat(".spokes.", label, ".proxy"));
    }

    /// @notice Records the call for the payload file and, on test networks, makes it.
    function _call(
        address target,
        bytes memory data,
        string memory label
    ) private {
        string memory k = string.concat("call.", vm.toString(callCount));
        vm.serializeAddress(k, "target", target);
        vm.serializeString(k, "label", label);
        string memory one = vm.serializeBytes(k, "data", data);
        calls = vm.serializeString("payload", vm.toString(callCount), one);
        ++callCount;
        if (execute) {
            (bool ok, bytes memory ret) = target.call(data);
            if (!ok) {
                console2.log("payload call failed:", label);
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }
}
