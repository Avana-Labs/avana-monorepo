// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {GlobalParams} from "../../../src/policy/parameter-store/types/GlobalParams.sol";
import {
    AaveInputs,
    ChainInputs,
    GovernanceInputs,
    HubInput,
    IntegrationInput,
    OperatorHelperInput
} from "./DeployTypes.sol";
import {Script} from "forge-std/Script.sol";

/// @title DeployInputs
/// @notice Reads a network's deployment inputs from `script/deploy/config/<network>.json`.
/// @dev Addresses are JSON strings. A string `"$<file>:<path>"` is a reference to an earlier step's output on the same
/// network, `deployments-local/<network>/<file>.json` at JSON path `<path>`: for example
/// `"$aave:.accessManager"` is the AccessManager `01_DeployAaveV4` deployed. Test networks (anvil, Tenderly, Sepolia)
/// use references; Ethereum and Base name every address literally. No key, RPC URL or secret is ever read from a file.
abstract contract DeployInputs is Script {
    /// @notice Directory of every script output, relative to `contracts/`.
    string internal constant OUTPUT_DIR = "deployments-local";

    /// @notice The network name the scripts run for: `AVANA_NETWORK`, default `anvil`.
    function _network() internal view returns (string memory) {
        return vm.envOr("AVANA_NETWORK", string("anvil"));
    }

    /// @notice `deployments-local/<network>/<file>.json`.
    function _outputPath(
        string memory file
    ) internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/", OUTPUT_DIR, "/", _network(), "/", file, ".json");
    }

    /// @notice Loads the inputs of `network` and checks the chain.
    function _loadInputs(
        string memory network
    ) internal view returns (ChainInputs memory c) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/script/deploy/config/", network, ".json"));
        c.network = network;
        c.chainId = vm.parseJsonUint(json, ".chainId");
        c.release = vm.envOr("AVANA_RELEASE", vm.parseJsonString(json, ".release"));
        require(c.chainId == block.chainid, string.concat("config ", network, " is for another chain"));
        c.gov = GovernanceInputs({
            governanceSafe: _addr(json, ".governance.governanceSafe"),
            emergencyGuardian: _addr(json, ".governance.emergencyGuardian"),
            aaveProtocolGuardian: _addr(json, ".governance.aaveProtocolGuardian"),
            aaveGovernanceExecutor: _addr(json, ".governance.aaveGovernanceExecutor"),
            jointConfigSafe: _addr(json, ".governance.jointConfigSafe")
        });
        c.aave = _aave(json);
        c.blockTime = uint32(vm.parseJsonUint(json, ".chain.blockTime"));
        c.hasSequencer = vm.parseJsonBool(json, ".chain.hasSequencer");
        c.sequencerFeed = _addr(json, ".chain.sequencerFeed");
        c.sequencerGraceSeconds = uint32(vm.parseJsonUint(json, ".chain.sequencerGraceSeconds"));
        c.globals = _globals(json);
        c.initialPoolShareMaxBps = uint16(vm.parseJsonUint(json, ".parameters.initialPoolShareMaxBps"));
        c.maxMarketCount = vm.parseJsonUint(json, ".parameters.maxMarketCount");
        c.keeperFloor = vm.parseJsonUint(json, ".parameters.keeperFloor");
        c.keepers = _addrs(json, ".keepers");
        c.operatorHelpers = _helpers(json);
        c.integrations = _integrations(json);
    }

    function _aave(
        string memory json
    ) private view returns (AaveInputs memory a) {
        a.accessManager = _addr(json, ".aave.accessManager");
        a.standardSpokeImplementation = _addr(json, ".aave.standardSpokeImplementation");
        a.v3Pool = _addr(json, ".aave.v3Pool");
        uint256 n = _count(json, ".aave.hubs");
        a.hubs = new HubInput[](n);
        for (uint256 i = 0; i < n; ++i) {
            string memory k = string.concat(".aave.hubs[", vm.toString(i), "]");
            a.hubs[i] = HubInput(
                _addr(json, string.concat(k, ".hub")), uint8(vm.parseJsonUint(json, string.concat(k, ".tier")))
            );
        }
    }

    function _globals(
        string memory json
    ) private view returns (GlobalParams memory g) {
        string memory p = ".parameters.globals";
        g.cachedWindow = uint32(vm.parseJsonUint(json, string.concat(p, ".cachedWindow")));
        g.disagreementPauseMax = uint32(vm.parseJsonUint(json, string.concat(p, ".disagreementPauseMax")));
        g.usdBandLow = vm.parseJsonUint(json, string.concat(p, ".usdBandLow"));
        g.usdBandHigh = vm.parseJsonUint(json, string.concat(p, ".usdBandHigh"));
        g.graceDuration = uint32(vm.parseJsonUint(json, string.concat(p, ".graceDuration")));
        g.graceHealthFactor = vm.parseJsonUint(json, string.concat(p, ".graceHealthFactor"));
        g.maxFlashFeeBps = uint16(vm.parseJsonUint(json, string.concat(p, ".maxFlashFeeBps")));
        g.avanaFeeShareBps = uint16(vm.parseJsonUint(json, string.concat(p, ".avanaFeeShareBps")));
        g.feeRecipient = _addr(json, string.concat(p, ".feeRecipient"));
        g.feedAgreementMarginBps = uint16(vm.parseJsonUint(json, string.concat(p, ".feedAgreementMarginBps")));
        g.gateRecoverySeconds = uint64(vm.parseJsonUint(json, string.concat(p, ".gateRecoverySeconds")));
        g.maxShortfallBps = uint16(vm.parseJsonUint(json, string.concat(p, ".maxShortfallBps")));
    }

    function _helpers(
        string memory json
    ) private view returns (OperatorHelperInput[] memory h) {
        uint256 n = _count(json, ".operatorHelpers");
        h = new OperatorHelperInput[](n);
        for (uint256 i = 0; i < n; ++i) {
            string memory k = string.concat(".operatorHelpers[", vm.toString(i), "]");
            h[i] = OperatorHelperInput(
                _addr(json, string.concat(k, ".signer")),
                _addr(json, string.concat(k, ".fundingSafe")),
                vm.parseJsonUint(json, string.concat(k, ".maxTopUpBps"))
            );
        }
    }

    function _integrations(
        string memory json
    ) private view returns (IntegrationInput[] memory out) {
        uint256 n = _count(json, ".integrations");
        out = new IntegrationInput[](n);
        for (uint256 i = 0; i < n; ++i) {
            string memory k = string.concat(".integrations[", vm.toString(i), "]");
            out[i].integrationId = uint32(vm.parseJsonUint(json, string.concat(k, ".integrationId")));
            out[i].kind = vm.parseJsonString(json, string.concat(k, ".kind"));
            out[i].positionManagers = _addrs(json, string.concat(k, ".positionManagers"));
            out[i].factories = _addrs(json, string.concat(k, ".factories"));
        }
    }

    // ─── Readers ───

    /// @notice Number of elements of the JSON array at `path` (0 when absent).
    function _count(
        string memory json,
        string memory path
    ) internal view returns (uint256 n) {
        while (vm.keyExistsJson(json, string.concat(path, "[", vm.toString(n), "]"))) {
            ++n;
        }
    }

    function _addrs(
        string memory json,
        string memory path
    ) internal view returns (address[] memory out) {
        uint256 n = _count(json, path);
        out = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = _addr(json, string.concat(path, "[", vm.toString(i), "]"));
        }
    }

    /// @notice An address, literal or a `$<file>:<path>` reference to an earlier output on this network.
    function _addr(
        string memory json,
        string memory path
    ) internal view returns (address) {
        string memory v = vm.parseJsonString(json, path);
        if (bytes(v).length == 0 || bytes(v)[0] != "$") return vm.parseAddress(v);
        string[] memory parts = vm.split(_drop(v, 1), ":");
        require(parts.length == 2, string.concat("bad reference ", v));
        string memory file = _outputPath(parts[0]);
        require(vm.exists(file), string.concat("missing output ", file, " for ", v, ": run the step that writes it"));
        return vm.parseJsonAddress(vm.readFile(file), parts[1]);
    }

    function _drop(
        string memory s,
        uint256 n
    ) private pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(b.length - n);
        for (uint256 i = n; i < b.length; ++i) {
            out[i - n] = b[i];
        }
        return string(out);
    }
}
