// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaCreate3Factory} from "../AvanaCreate3Factory.sol";
import {DeployInputs} from "./DeployInputs.sol";

/// @title DeployBase
/// @notice Artifact loading, CREATE and namespaced CREATE3 deployment for every deploy step.
/// @dev Every Avana contract is deployed from its release artifact in `out/` (never from code compiled into the
/// script), so the runtime code on chain is the code the bytecode check compares (`TEST-134`). A file restricted to
/// another compiler profile in `foundry.toml` (`compilation_restrictions`) has its artifact under that profile's
/// suffix, `out/<File>.sol/<Contract>.<profile>.json`; every other contract uses `out/<File>.sol/<Contract>.json`.
/// Calls run as whoever the caller has made the sender: `vm.startBroadcast(deployer)` in a script, `vm.startPrank`
/// in a test.
abstract contract DeployBase is DeployInputs {
    /// @notice Safe Singleton Factory (CREATE2 with `salt ‖ initcode` calldata), present on Ethereum, Base, Sepolia and
    /// Base Sepolia; `00_Factories` installs it on anvil.
    address internal constant SAFE_SINGLETON_FACTORY = 0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7;

    /// @notice Runtime code of the Safe Singleton Factory.
    bytes internal constant SAFE_SINGLETON_FACTORY_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    /// @notice The namespaced CREATE3 factory and the account whose namespace the deployment uses.
    AvanaCreate3Factory internal create3;
    address internal deployer;
    string internal release;

    /// @notice CREATE2 address of `AvanaCreate3Factory` through the Safe Singleton Factory with salt 0.
    function _create3FactoryAddress() internal view returns (address) {
        bytes32 h = keccak256(_artifact("AvanaCreate3Factory.sol", "AvanaCreate3Factory"));
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), SAFE_SINGLETON_FACTORY, bytes32(0), h)))));
    }

    /// @notice Salt of an Avana contract in this release: `keccak256("avana.<release>.<name>")`.
    function _salt(
        string memory name
    ) internal view returns (bytes32) {
        return keccak256(bytes(string.concat("avana.", release, ".", name)));
    }

    /// @notice The address `name` gets in the deployer's namespace.
    function _predict(
        string memory name
    ) internal view returns (address) {
        return create3.predict(deployer, _salt(name));
    }

    /// @notice Deploys `initCode` at `_predict(name)` and checks the address.
    function _deploy3(
        string memory name,
        bytes memory initCode
    ) internal returns (address deployed) {
        address expected = _predict(name);
        require(expected.code.length == 0, string.concat(name, " already deployed at its address"));
        deployed = create3.deploy(_salt(name), initCode);
        require(deployed == expected, string.concat(name, " landed off its prediction"));
        vm.label(deployed, name);
    }

    /// @notice Plain CREATE from the sender (implementations and logic contracts, whose address is recorded).
    function _deploy(
        string memory name,
        bytes memory initCode
    ) internal returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(deployed != address(0), string.concat(name, ": constructor reverted"));
        vm.label(deployed, name);
    }

    /// @notice The contract an earlier run of a step recorded under `key` in output `file`, or 0 when there is none or
    /// it has no code (each step lists only what is not on chain yet).
    function _recorded(
        string memory file,
        string memory key
    ) internal view returns (address a) {
        string memory path = _outputPath(file);
        if (!vm.exists(path)) return address(0);
        string memory json = vm.readFile(path);
        if (!vm.keyExistsJson(json, key)) return address(0);
        a = vm.parseJsonAddress(json, key);
        if (a.code.length == 0) a = address(0);
    }

    /// @notice Starts serializing JSON object `obj` from output `file`, so a step that adds entries keeps the earlier
    /// ones; returns the file's JSON, or "" when there is no file yet.
    function _keepOutput(
        string memory obj,
        string memory file
    ) internal returns (string memory json) {
        string memory path = _outputPath(file);
        if (vm.exists(path)) json = vm.serializeJson(obj, vm.readFile(path));
    }

    /// @notice Whether `aavePayload.debtAssets[i]` goes on Hub `label`: every Hub, or only those its `hubs` list names.
    function _assetOnHub(
        string memory c,
        uint256 i,
        string memory label
    ) internal view returns (bool) {
        string memory k = string.concat(".aavePayload.debtAssets[", vm.toString(i), "].hubs");
        if (!vm.keyExistsJson(c, k)) return true;
        string[] memory hubs = vm.parseJsonStringArray(c, k);
        for (uint256 j = 0; j < hubs.length; ++j) {
            if (keccak256(bytes(hubs[j])) == keccak256(bytes(label))) return true;
        }
        return false;
    }

    /// @notice Whether `aavePayload.debtAssets[i]` is only lent (`lendOnly`): on the Lend Spoke, never borrowed by a CDP
    /// Spoke, so it has no First-Loss Reserve or deficit offset either.
    function _assetLendOnly(
        string memory c,
        uint256 i
    ) internal view returns (bool) {
        string memory k = string.concat(".aavePayload.debtAssets[", vm.toString(i), "].lendOnly");
        return vm.keyExistsJson(c, k) && vm.parseJsonBool(c, k);
    }

    /// @notice Whether (Hub `h`, asset `i`) of `aavePayload` has loss layers: the asset is on the Hub and borrowable.
    function _coveredPair(
        string memory c,
        uint256 h,
        uint256 i
    ) internal view returns (bool) {
        string memory label = vm.parseJsonString(c, string.concat(".aavePayload.hubs[", vm.toString(h), "].label"));
        return _assetOnHub(c, i, label) && !_assetLendOnly(c, i);
    }

    /// @notice Creation code of `<Contract>` in `out/<file>/`, from the profile the file is deployed with.
    function _artifact(
        string memory file,
        string memory name
    ) internal view returns (bytes memory) {
        return _artifactIn("out", file, name);
    }

    /// @notice Artifact path of `name` from `file` under `outDir` for the profile the file is deployed with.
    function _artifactPath(
        string memory outDir,
        string memory file,
        string memory name
    ) internal view returns (string memory path) {
        string memory dir = string.concat(vm.projectRoot(), "/", outDir, "/", file, "/");
        string memory profile = _profileOf(file);
        if (bytes(profile).length != 0) {
            path = string.concat(dir, name, ".", profile, ".json");
            if (vm.exists(path)) return path;
        }
        path = string.concat(dir, name, ".json");
    }

    function _artifactIn(
        string memory outDir,
        string memory file,
        string memory name
    ) internal view returns (bytes memory) {
        string memory path = _artifactPath(outDir, file, name);
        require(vm.exists(path), string.concat("no artifact ", path, ": build first"));
        // getCode reads only the creation code: loading whole artifact JSON (ABI, AST) into script memory for every
        // contract exhausts the script's memory limit (MemoryOOG) long before the deployment ends.
        return vm.getCode(path);
    }

    /// @notice Creation code of `name` with each external library placeholder (`__$<34 hex of keccak(fqn)>$__`) replaced
    /// by its deployed address, as Foundry links at build time; `fqns[i]` is `<source path>:<Library>`.
    function _artifactLinked(
        string memory outDir,
        string memory file,
        string memory name,
        string[] memory fqns,
        address[] memory libs
    ) internal view returns (bytes memory) {
        string memory path = _artifactPath(outDir, file, name);
        string memory code = vm.parseJsonString(vm.readFile(path), ".bytecode.object");
        for (uint256 i = 0; i < fqns.length; ++i) {
            string memory h = vm.toString(keccak256(bytes(fqns[i])));
            string memory placeholder = string.concat("__$", _substring(h, 2, 36), "$__");
            require(vm.indexOf(code, placeholder) != type(uint256).max, string.concat(name, " does not link ", fqns[i]));
            code = vm.replace(code, placeholder, _substring(vm.toString(libs[i]), 2, 42));
        }
        return vm.parseBytes(code);
    }

    function _substring(
        string memory s,
        uint256 a,
        uint256 b
    ) internal pure returns (string memory) {
        bytes memory x = bytes(s);
        bytes memory out = new bytes(b - a);
        for (uint256 i = a; i < b; ++i) {
            out[i - a] = x[i];
        }
        return string(out);
    }

    /// @notice True when the artifact of `name` exists in `out/`.
    function _hasArtifact(
        string memory file,
        string memory name
    ) internal view returns (bool) {
        return vm.exists(_artifactPath("out", file, name));
    }

    /// @notice The `additional_compiler_profiles` name a deployable file is restricted to in `foundry.toml`, or "" for
    /// the default profile. Mirrors `compilation_restrictions`: via-IR at 200 runs (Collateralization, DebtOracle, the
    /// LPVaultSwap logic contracts, the Lens modules), 1,000 runs (the concentrated-liquidity LPVaults), 200 runs
    /// without IR (the LPOracle implementations and their logic contracts).
    function _profileOf(
        string memory file
    ) internal pure returns (string memory) {
        if (
            _eq(file, "Collateralization.sol") || _startsWith(file, "DebtOracle")
                || (_startsWith(file, "LPVaultSwap") && _endsWith(file, "Logic.sol"))
                || (_startsWith(file, "Lens") && _endsWith(file, "Module.sol"))
        ) return "collateralization";
        if (_eq(file, "UniswapV3Integration.sol") || _eq(file, "SlipstreamIntegration.sol")) return "clvault";
        if (_startsWith(file, "LPOracle")) return "lporacle";
        return "";
    }

    function _eq(
        string memory a,
        string memory b
    ) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _startsWith(
        string memory s,
        string memory p
    ) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(p);
        if (b.length > a.length) return false;
        for (uint256 i = 0; i < b.length; ++i) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    function _endsWith(
        string memory s,
        string memory p
    ) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(p);
        if (b.length > a.length) return false;
        for (uint256 i = 0; i < b.length; ++i) {
            if (a[a.length - b.length + i] != b[i]) return false;
        }
        return true;
    }
}
