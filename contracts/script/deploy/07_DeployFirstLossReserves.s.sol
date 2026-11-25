// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/dependencies/aave/IAaveV4Hub.sol";
import {IFirstLossReserve} from "../../src/interfaces/IFirstLossReserve.sol";
import {CoreRecord} from "./lib/CoreRecord.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";

/// @notice The test tokens' open mint (`TestToken`), used on a local chain only.
interface ITestTokenMinter {
    function mint(
        address to,
        uint256 amount
    ) external;
}

/// @title DeployFirstLossReserves
/// @notice Step 7, the two loss layers of every covered `(Hub, debt asset)` of `aavePayload` (an asset on the Hub that
/// is not `lendOnly`): Avana's First-Loss Reserve (`firstLossLayer = 0`) and behind it the DAO Deficit Offset (the same
/// contract with the Avana reserve as its layer in front), both governed by the Aave AccessManager.
/// - `AVANA_COVERAGE_STEP=deploy` (default): deploys the missing layers and writes
///   `deployments-local/<network>/coverage.json`. `08_AaveLossLayersPayload` then registers them on Aave.
/// - `AVANA_COVERAGE_STEP=fund`: the funder (`coverage.funder`) tops Avana's layer up to its minimum
///   (`aavePayload.debtAssets[i].coverageMinimum`, whole tokens); on a local chain the token's minter mints what the
///   funder lacks. The DAO funds its offset itself.
/// @dev Each layer is CREATE3-deployed by 03's deployer under `FirstLossReserve.<hub label>.<symbol>` and
/// `DaoDeficitOffset.<hub label>.<symbol>`.
contract DeployFirstLossReserves is CoreRecord {
    string internal cfg;

    struct Layer {
        string hubLabel;
        string symbol;
        address hub;
        address asset;
        uint256 assetId;
        address avana;
        address offset;
        uint256 minimum;
        uint256 offsetMinimum;
    }

    function run() external {
        cfg = vm.readFile(_configPath(_network()));
        _useCoreNamespace();
        string memory step = vm.envOr("AVANA_COVERAGE_STEP", string("deploy"));
        Layer[] memory layers = _layers();
        if (_eq(step, "deploy")) {
            _deployLayers(layers);
            _write(layers);
        } else if (_eq(step, "fund")) {
            _fund(layers);
        } else {
            revert(string.concat("AVANA_COVERAGE_STEP ", step, ": deploy or fund"));
        }
    }

    /// @notice Every covered pair of the config, with its layers' predicted addresses.
    function _layers() private view returns (Layer[] memory out) {
        uint256 nHubs = _count(cfg, ".aavePayload.hubs");
        uint256 nAssets = _count(cfg, ".aavePayload.debtAssets");
        out = new Layer[](nHubs * nAssets);
        uint256 n;
        for (uint256 h = 0; h < nHubs; ++h) {
            for (uint256 i = 0; i < nAssets; ++i) {
                if (!_coveredPair(cfg, h, i)) continue;
                string memory ak = string.concat(".aavePayload.debtAssets[", vm.toString(i), "]");
                Layer memory l = out[n++];
                l.hubLabel = vm.parseJsonString(cfg, string.concat(".aavePayload.hubs[", vm.toString(h), "].label"));
                l.symbol = vm.parseJsonString(cfg, string.concat(ak, ".symbol"));
                l.hub = _hubOf(cfg, l.hubLabel);
                l.asset = _addr(cfg, string.concat(ak, ".token"));
                uint256 unit = 10 ** uint256(vm.parseJsonUint(cfg, string.concat(ak, ".decimals")));
                l.minimum = vm.parseJsonUint(cfg, string.concat(ak, ".coverageMinimum")) * unit;
                l.offsetMinimum = vm.parseJsonUint(cfg, string.concat(ak, ".offsetMinimum")) * unit;
                l.avana = _predict(_name("FirstLossReserve", l));
                l.offset = _predict(_name("DaoDeficitOffset", l));
            }
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    function _name(
        string memory kind,
        Layer memory l
    ) private pure returns (string memory) {
        return string.concat(kind, ".", l.hubLabel, ".", l.symbol);
    }

    function _deployLayers(
        Layer[] memory layers
    ) private {
        address aaveManager = _addr(cfg, ".aave.accessManager");
        vm.startBroadcast(deployer);
        for (uint256 i = 0; i < layers.length; ++i) {
            Layer memory l = layers[i];
            l.assetId = IAaveV4Hub(l.hub).getAssetId(l.asset);
            bytes memory code = _artifact("FirstLossReserve.sol", "FirstLossReserve");
            if (l.avana.code.length == 0) {
                _deploy3(
                    _name("FirstLossReserve", l),
                    bytes.concat(code, abi.encode(l.hub, l.asset, l.assetId, aaveManager, address(0)))
                );
            }
            if (l.offset.code.length == 0) {
                _deploy3(
                    _name("DaoDeficitOffset", l),
                    bytes.concat(code, abi.encode(l.hub, l.asset, l.assetId, aaveManager, l.avana))
                );
            }
            console2.log(_name("FirstLossReserve", l), l.avana);
            console2.log(_name("DaoDeficitOffset", l), l.offset);
        }
        vm.stopBroadcast();
    }

    function _fund(
        Layer[] memory layers
    ) private {
        address funder = _addr(cfg, ".coverage.funder");
        for (uint256 i = 0; i < layers.length; ++i) {
            Layer memory l = layers[i];
            require(l.avana.code.length != 0, string.concat(_name("FirstLossReserve", l), " not deployed: run deploy"));
            uint256 funded = IFirstLossReserve(l.avana).fundedBalance();
            if (funded >= l.minimum) {
                console2.log(string.concat(_name("FirstLossReserve", l), ": at its minimum"), funded);
                continue;
            }
            // Hub shares round down: one extra unit keeps the funded balance at or above the minimum.
            uint256 amount = l.minimum - funded + 1;
            uint256 balance = IERC20(l.asset).balanceOf(funder);
            if (balance < amount) {
                require(_isLocalChain(block.chainid), string.concat("the funder holds too little ", l.symbol));
                vm.broadcast(_addr(cfg, ".aavePayload.tokenMinter"));
                ITestTokenMinter(l.asset).mint(funder, amount - balance);
            }
            vm.startBroadcast(funder);
            IERC20(l.asset).approve(l.avana, amount);
            IFirstLossReserve(l.avana).fund(amount);
            vm.stopBroadcast();
            console2.log(string.concat(_name("FirstLossReserve", l), ": funded"), amount);
        }
    }

    function _write(
        Layer[] memory layers
    ) private {
        uint256 n = layers.length;
        string[] memory labels = new string[](n);
        string[] memory symbols = new string[](n);
        address[] memory hubs = new address[](n);
        address[] memory assets = new address[](n);
        address[] memory avana = new address[](n);
        address[] memory offsets = new address[](n);
        uint256[] memory minimums = new uint256[](n);
        uint256[] memory offsetMinimums = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            Layer memory l = layers[i];
            (labels[i], symbols[i], hubs[i], assets[i]) = (l.hubLabel, l.symbol, l.hub, l.asset);
            (avana[i], offsets[i], minimums[i], offsetMinimums[i]) = (l.avana, l.offset, l.minimum, l.offsetMinimum);
        }
        string memory o = "coverage";
        vm.serializeString(o, "hubLabels", labels);
        vm.serializeString(o, "symbols", symbols);
        vm.serializeAddress(o, "hubs", hubs);
        vm.serializeAddress(o, "assets", assets);
        vm.serializeAddress(o, "avanaLayers", avana);
        vm.serializeAddress(o, "daoOffsets", offsets);
        vm.serializeUint(o, "minimums", minimums);
        string memory json = vm.serializeUint(o, "offsetMinimums", offsetMinimums);
        vm.writeJson(json, _outputPath("coverage"));
        console2.log("output", _outputPath("coverage"));
    }
}
