// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAvanaFirstLossReserve} from "../../src/coverage/first-loss-reserve/IAvanaFirstLossReserve.sol";
import {DeployBase} from "./lib/DeployBase.sol";
import {console2} from "forge-std/console2.sol";

interface IHubAssets {
    function getAssetId(
        address underlying
    ) external view returns (uint256);
}

interface IFaucetToken {
    function mint(
        address to,
        uint256 amount
    ) external;
    function approve(
        address spender,
        uint256 amount
    ) external returns (bool);
}

/// @title DeployAvanaFirstLossReserves
/// @notice Step 12 of the deployment order: the Avana Umbrella (First-Loss Reserve) of each (Hub, debt asset), deployed by
/// Avana once the Hub lists the asset (its constructor checks the Hub's asset ID, `REQ-FLR-008`) and before the Aave
/// DAO's loss-layer AIP registers it (`08_AaveLossLayersPayload`), which names it by address. `AVANA_COVERAGE_STEP`:
/// - `deploy`: `AvanaFirstLossReserve(hub, asset, assetId, aaveAccessManager, 1,209,600)` per pair; writes `coverage.json`.
/// - `fund`: after the AIP has set each Umbrella's `firstLossReserveMinimum`, Avana Labs funds it to that minimum
///   (`REQ-FLR-011`), so it is not below its minimum when `enableDebtReserve` reads it.
/// @dev The pairs are `aavePayload.hubs` × `aavePayload.debtAssets`; the Aave addresses come from the config. Funding on
/// a test network mints the faucet token to `coverage.funder` first.
contract DeployAvanaFirstLossReserves is DeployBase {
    string internal cfg;

    function run() external {
        cfg = vm.readFile(_configPath(_network()));
        string memory step = vm.envString("AVANA_COVERAGE_STEP");
        if (_eq(step, "deploy")) _deployAll();
        else if (_eq(step, "fund")) _fundAll();
        else revert(string.concat("unknown AVANA_COVERAGE_STEP ", step));
    }

    function _pairs() private view returns (uint256 nHubs, uint256 nAssets) {
        nHubs = _count(cfg, ".aavePayload.hubs");
        nAssets = _count(cfg, ".aavePayload.debtAssets");
    }

    function _hubOf(
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

    function _name(
        uint256 h,
        uint256 i
    ) private view returns (string memory label, string memory symbol, address hub, address token) {
        label = vm.parseJsonString(cfg, string.concat(".aavePayload.hubs[", vm.toString(h), "].label"));
        string memory ak = string.concat(".aavePayload.debtAssets[", vm.toString(i), "]");
        symbol = vm.parseJsonString(cfg, string.concat(ak, ".symbol"));
        hub = _hubOf(label);
        token = _addr(cfg, string.concat(ak, ".token"));
    }

    function _deployAll() private {
        (uint256 nHubs, uint256 nAssets) = _pairs();
        // Earlier entries are kept; a pair whose First-Loss Reserve is deployed already is skipped.
        string memory json = _keepOutput("coverage", "coverage");
        bool added;
        vm.startBroadcast();
        for (uint256 h = 0; h < nHubs; ++h) {
            for (uint256 i = 0; i < nAssets; ++i) {
                if (!_coveredPair(cfg, h, i)) continue;
                (string memory label, string memory symbol,,) = _name(h, i);
                string memory name = string.concat("AvanaFirstLossReserve.", label, ".", symbol);
                address done = _recorded("coverage", string.concat("$['", name, "']"));
                if (done != address(0)) {
                    console2.log(name, done, "(deployed earlier)");
                    continue;
                }
                json = _deployOne(h, i);
                added = true;
            }
        }
        vm.stopBroadcast();
        if (added) vm.writeJson(json, _outputPath("coverage"));
    }

    function _deployOne(
        uint256 h,
        uint256 i
    ) private returns (string memory json) {
        (string memory label, string memory symbol, address hub, address token) = _name(h, i);
        string memory name = string.concat("AvanaFirstLossReserve.", label, ".", symbol);
        bytes memory args = abi.encode(
            hub, token, IHubAssets(hub).getAssetId(token), _addr(cfg, ".aave.accessManager"), uint256(1_209_600)
        );
        address cs = _deploy(name, bytes.concat(_artifact("AvanaFirstLossReserve.sol", "AvanaFirstLossReserve"), args));
        json = vm.serializeAddress("coverage", name, cs);
        console2.log(name, cs);
    }

    function _fundAll() private {
        (uint256 nHubs, uint256 nAssets) = _pairs();
        string memory coverage = vm.readFile(_outputPath("coverage"));
        address funder = _addr(cfg, ".coverage.funder");
        bool faucet = block.chainid != 1 && block.chainid != 8453;
        for (uint256 h = 0; h < nHubs; ++h) {
            for (uint256 i = 0; i < nAssets; ++i) {
                if (!_coveredPair(cfg, h, i)) continue;
                (string memory label, string memory symbol,, address token) = _name(h, i);
                IAvanaFirstLossReserve cs = IAvanaFirstLossReserve(
                    vm.parseJsonAddress(coverage, string.concat("$['AvanaFirstLossReserve.", label, ".", symbol, "']"))
                );
                uint256 minimum = cs.firstLossReserveMinimum();
                uint256 balance = cs.fundedBalance();
                if (minimum <= balance) continue;
                uint256 amount = minimum - balance;
                vm.startBroadcast(funder);
                if (faucet) IFaucetToken(token).mint(funder, amount);
                IFaucetToken(token).approve(address(cs), amount);
                cs.fund(amount);
                vm.stopBroadcast();
                console2.log("funded", label, symbol, amount);
            }
        }
    }
}
