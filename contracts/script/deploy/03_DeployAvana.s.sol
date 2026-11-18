// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaCreate3Factory} from "./AvanaCreate3Factory.sol";
import {AvanaDeploy} from "./lib/AvanaDeploy.sol";
import {AvanaDeployment, ChainInputs} from "./lib/DeployTypes.sol";
import {DeploymentOutput} from "./lib/DeploymentOutput.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployAvana
/// @notice Step 3: the AccessManager and every Avana contract of one chain (`script/README.md`, deployment order).
/// @dev Inputs: `script/deploy/config/$AVANA_NETWORK.json` (its `chainId` must be the RPC's), `AVANA_RELEASE` overrides
/// the config's release; it is a release tag, and off anvil HEAD is that tag (`DeployInputs._checkRelease`). A
/// release record (`AVANA_RELEASE_RECORD`, or `deployments-local/<network>/release.json`) must name the same release,
/// commit, salts and, for this deployer, addresses. The deployer is the broadcasting account (`--account`, `--ledger` or, on anvil, an unlocked
/// test key); it ends with no role anywhere. Output: `deployments-local/<network>/avana.json`.
contract DeployAvana is AvanaDeploy, DeploymentOutput {
    function run() external returns (AvanaDeployment memory d) {
        ChainInputs memory c = _loadInputs(_network());
        release = c.release;
        create3 = AvanaCreate3Factory(_create3FactoryAddress());
        vm.startBroadcast();
        (, deployer,) = vm.readCallers();
        string memory record = _releaseRecordPath();
        if (bytes(record).length != 0) {
            _checkReleaseRecord(record, _requireReleaseCheckout(release));
            console2.log("release record matches:", record);
        }
        d = _deployAvana(c);
        vm.stopBroadcast();
        vm.createDir(string.concat(vm.projectRoot(), "/", OUTPUT_DIR, "/", c.network), true);
        _writeAvanaOutput(_outputPath("avana"), c, d);
        console2.log("AccessManager", d.accessManager);
        console2.log("MarketRegistry", d.marketRegistry.proxy);
        console2.log("AaveAdapter", d.aaveAdapter.proxy);
        console2.log("LPVaultSwap", d.lpVaultSwap.proxy);
        console2.log("output", _outputPath("avana"));
    }
}
