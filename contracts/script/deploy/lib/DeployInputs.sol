// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {
    AaveInputs,
    ChainInputs,
    GlobalParams,
    GovernanceInputs,
    HubInput,
    IntegrationInput,
    OperatorHelperInput
} from "./DeployTypes.sol";
import {Script} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title DeployInputs
/// @notice Reads a network's deployment inputs from `script/deploy/config/<network>.json`.
/// @dev Addresses are JSON strings. A string `"$<file>:<path>"` is a reference to an earlier step's output on the same
/// network, `deployments-local/<network>/<file>.json` at JSON path `<path>`: for example
/// `"$aave:.accessManager"` is the AccessManager `01_DeployAaveV4` deployed. Test networks (anvil, Sepolia)
/// use references; Ethereum and Base name every address literally. No key, RPC URL or secret is ever read from a file.
abstract contract DeployInputs is Script {
    /// @notice Directory of every script output, relative to `contracts/`.
    string internal constant OUTPUT_DIR = "deployments-local";

    /// @notice The network's config file: `AVANA_CONFIG` when set (a path from `contracts/`, for a config with later
    /// additions), else `script/deploy/config/<network>.json`.
    function _configPath(
        string memory network
    ) internal view returns (string memory) {
        string memory over = vm.envOr("AVANA_CONFIG", string(""));
        if (bytes(over).length != 0) return string.concat(vm.projectRoot(), "/", over);
        return string.concat(vm.projectRoot(), "/script/deploy/config/", network, ".json");
    }

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

    /// @notice Chain IDs of the local anvil nodes, the only chains that take a learning tag or a checkout that is not the
    /// release tag: 31337 (the rehearsal's node and the local stack's Ethereum) and 31338 (the local stack's Base, 2 s
    /// blocks). The chain ID, not the network name, makes a run local: the local stack names its chains `ethereum` and
    /// `base`, as on the real networks.
    uint256 internal constant ANVIL_CHAIN_ID = 31_337;
    uint256 internal constant ANVIL_BASE_CHAIN_ID = 31_338;

    /// @notice True on a local anvil chain.
    function _isLocalChain(
        uint256 chainId
    ) internal pure returns (bool) {
        return chainId == ANVIL_CHAIN_ID || chainId == ANVIL_BASE_CHAIN_ID;
    }

    /// @notice What the release check compares with HEAD: the deployed sources and their build settings.
    string internal constant RELEASE_SOURCES = "src script/deploy foundry.toml soldeer.lock remappings.txt";

    /// @notice Loads the inputs of `network`, checks the chain and the release (`_requireReleaseCheckout`).
    function _loadInputs(
        string memory network
    ) internal returns (ChainInputs memory c) {
        string memory json = vm.readFile(_configPath(network));
        c.network = network;
        c.chainId = vm.parseJsonUint(json, ".chainId");
        c.release = vm.envOr("AVANA_RELEASE", vm.parseJsonString(json, ".release"));
        require(c.chainId == block.chainid, string.concat("config ", network, " is for another chain"));
        _requireReleaseCheckout(c.release);
        c.gov = GovernanceInputs({
            governanceSafe: _addr(json, ".governance.governanceSafe"),
            emergencyGuardian: _addr(json, ".governance.emergencyGuardian"),
            aaveProtocolGuardian: _addr(json, ".governance.aaveProtocolGuardian"),
            aaveGovernanceExecutor: _addr(json, ".governance.aaveGovernanceExecutor"),
            jointConfigSafe: _addr(json, ".governance.jointConfigSafe")
        });
        c.aave = _aave(json);
        c.blockTime = uint32(vm.parseJsonUint(json, ".chain.blockTime"));
        c.globals = _globals(json);
        c.maxMarketCount = vm.parseJsonUint(json, ".parameters.maxMarketCount");
        c.keeperFloor = vm.parseJsonUint(json, ".parameters.keeperFloor");
        c.timelockNormalDelay = vm.parseJsonUint(json, ".parameters.timelockNormalDelay");
        c.keepers = _addrs(json, ".keepers");
        c.operatorHelpers = _helpers(json);
        c.integrations = _integrations(json);
    }

    // ─── Release check ───

    /// @notice Checks `release` (`_checkRelease`); off anvil it first reads HEAD, the tag's commit and any uncommitted
    /// change to `RELEASE_SOURCES` from git, which needs forge's `--ffi` (`step.sh` passes it off anvil). Without it the
    /// script stops: a release is never deployed outside anvil unchecked.
    /// @return head The 20-byte HEAD commit off anvil, empty on anvil.
    function _requireReleaseCheckout(
        string memory release_
    ) internal returns (bytes memory head) {
        bytes memory tagCommit;
        bytes memory dirty;
        if (!_isLocalChain(block.chainid) && _isReleaseTag(release_) && !_isLearningRelease(release_)) {
            head = _gitCommit("HEAD");
            tagCommit = _gitCommit(string.concat("refs/tags/", release_, "^{commit}"));
            bool ok;
            (ok, dirty) =
                _git(vm.split(string.concat("status --porcelain --untracked-files=no -- ", RELEASE_SOURCES), " "));
            if (!ok) dirty = "git status failed";
        }
        _checkRelease(release_, block.chainid, head, tagCommit, dirty);
    }

    /// @notice The release rules: `release` is a tag `vX.Y.Z` or `vX.Y.Z-<pre-release>` (the manifest schema's
    /// pattern) on every chain. Off anvil it is not a learning tag (`-local`, `-test`, `-learn`), HEAD is the tag's
    /// commit and the deployed sources have no uncommitted change, so the build in `out/` is the tagged code whose
    /// release record the release workflow published.
    function _checkRelease(
        string memory release_,
        uint256 chainId,
        bytes memory head,
        bytes memory tagCommit,
        bytes memory dirty
    ) internal pure {
        require(
            _isReleaseTag(release_),
            string.concat("AVANA_RELEASE ", release_, " is not a release tag vX.Y.Z or vX.Y.Z-<pre-release>")
        );
        if (_isLocalChain(chainId)) return;
        require(
            !_isLearningRelease(release_),
            string.concat("AVANA_RELEASE ", release_, " is a learning tag, for anvil only")
        );
        require(tagCommit.length != 0, string.concat("no git tag ", release_, " in this checkout"));
        require(
            keccak256(head) == keccak256(tagCommit),
            string.concat(
                "HEAD ",
                vm.toString(head),
                " is not ",
                release_,
                " (",
                vm.toString(tagCommit),
                "): check out the release tag"
            )
        );
        require(dirty.length == 0, string.concat("uncommitted changes to the deployed sources:\n", string(dirty)));
    }

    /// @notice `^v[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9.]+)?$`.
    function _isReleaseTag(
        string memory r
    ) internal pure returns (bool) {
        bytes memory b = bytes(r);
        if (b.length < 6 || b[0] != "v") return false;
        uint256 i = 1;
        for (uint256 part = 0; part < 3; ++part) {
            uint256 start = i;
            while (i < b.length && b[i] >= "0" && b[i] <= "9") {
                ++i;
            }
            if (i == start) return false;
            if (part < 2) {
                if (i == b.length || b[i] != ".") return false;
                ++i;
            }
        }
        if (i == b.length) return true;
        if (b[i] != "-" || i + 1 == b.length) return false;
        for (++i; i < b.length; ++i) {
            bytes1 ch = b[i];
            if (!((ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") || ch == ".")) return false;
        }
        return true;
    }

    /// @notice A learning tag: its pre-release starts with `local`, `test` or `learn` (the release workflow's rule).
    function _isLearningRelease(
        string memory r
    ) internal pure returns (bool) {
        bytes memory b = bytes(r);
        uint256 dash = b.length;
        for (uint256 i = 0; i < b.length; ++i) {
            if (b[i] == "-") {
                dash = i;
                break;
            }
        }
        if (dash == b.length) return false;
        string memory pre = _drop(r, dash + 1);
        return _hasPrefix(pre, "local") || _hasPrefix(pre, "test") || _hasPrefix(pre, "learn");
    }

    /// @notice Runs `git <args>` in `contracts/`: whether it exited 0, and its output.
    function _git(
        string[] memory args
    ) internal returns (bool ok, bytes memory out) {
        string[] memory cmd = new string[](args.length + 1);
        cmd[0] = "git";
        for (uint256 i = 0; i < args.length; ++i) {
            cmd[i + 1] = args[i];
        }
        Vm.FfiResult memory r = vm.tryFfi(cmd);
        return (r.exitCode == 0, r.stdout);
    }

    /// @notice The 20-byte commit `ref` names, empty when there is none (no such tag).
    function _gitCommit(
        string memory ref
    ) internal returns (bytes memory commit) {
        string[] memory args = new string[](3);
        (args[0], args[1], args[2]) = ("rev-parse", "--verify", ref);
        bool ok;
        (ok, commit) = _git(args);
        if (!ok) return "";
        // forge hex-decodes output that is hex: the 40 digits usually arrive as 20 bytes already.
        if (commit.length == 40) commit = vm.parseBytes(string.concat("0x", string(commit)));
        require(commit.length == 20, string.concat("git rev-parse ", ref, " printed no commit"));
    }

    function _hasPrefix(
        string memory s,
        string memory prefix
    ) private pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory p = bytes(prefix);
        if (a.length < p.length) return false;
        for (uint256 i = 0; i < p.length; ++i) {
            if (a[i] != p[i]) return false;
        }
        return true;
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
        g.maxFlashFeeBps = uint16(vm.parseJsonUint(json, string.concat(p, ".maxFlashFeeBps")));
        g.avanaFeeShareBps = uint16(vm.parseJsonUint(json, string.concat(p, ".avanaFeeShareBps")));
        g.feeRecipient = _addr(json, string.concat(p, ".feeRecipient"));
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
