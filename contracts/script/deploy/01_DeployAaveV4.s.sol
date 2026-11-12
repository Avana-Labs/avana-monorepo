// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DeployBase} from "./lib/DeployBase.sol";
import {AaveV4Bootstrap} from "./local/AaveV4Bootstrap.sol";
import {console2} from "forge-std/console2.sol";

interface IAuthorityBatch {
    function getReport() external view returns (address accessManager);
}

interface IConfiguratorBatch {
    function getReport() external view returns (address hubConfigurator, address spokeConfigurator);
}

interface ITreasurySpokeBatch {
    function getReport() external view returns (address treasurySpoke);
}

interface IHubInstanceBatch {
    function getReport() external view returns (address hubProxy, address hubImplementation, address irStrategy);
}

interface ISpokeInstanceBatch {
    function getReport() external view returns (address spokeProxy, address spokeImplementation, address aaveOracle);
}

/// @notice Aave's role procedures as `aave-deploy/AvanaAaveV4Roles.sol` exposes them.
interface IAaveV4Roles {
    function labelAllRoles(
        address accessManager
    ) external;
    function setupConfigurators(
        address accessManager,
        address hubConfigurator,
        address spokeConfigurator
    ) external;
    function setupHub(
        address accessManager,
        address hub
    ) external;
    function setupSpoke(
        address accessManager,
        address spoke
    ) external;
    function grantHubRoles(
        address accessManager,
        address hubConfigurator,
        address hubAdmin,
        address hubConfiguratorAdmin
    ) external;
    function grantSpokeRoles(
        address accessManager,
        address spokeConfigurator,
        address spokeAdmin,
        address spokeConfiguratorAdmin
    ) external;
    function replaceDefaultAdminRole(
        address accessManager,
        address adminToAdd,
        address adminToRemove
    ) external;
}

/// @title DeployAaveV4
/// @notice Step 1 on test networks (anvil, Tenderly, Sepolia): Avana's own Aave V4 from the pinned release a3ef63e,
/// following Aave's deploy orchestration step for step with the batch contracts of `out-aave/`: the AccessManager, the
/// HubConfigurator and SpokeConfigurator, the TreasurySpoke, every Hub of the network's `aaveLocal.hubs` with its
/// interest-rate strategy, and every Spoke of `aaveLocal.spokes` (CDP Spokes per AMM protocol and risk tier, Lend
/// Spokes per Hub) with its own 8-decimal AaveOracle, `LiquidationLogic` at its CREATE2 address. Roles end where the
/// orchestration with `grantRoles = true` leaves them, with `aaveLocal.aaveDao` as Hub admin, Spoke admin, both
/// configurator admins and AccessManager admin. Assets, reserves, caps and Spoke registrations are the Aave payloads of
/// `06_AaveListing`. Never runs on Ethereum or Base, where the Aave DAO deploys and owns Aave V4.
/// Output: `deployments-local/<network>/aave.json`.
contract DeployAaveV4 is DeployBase {
    bytes32 internal constant AAVE_V4_SALT = keccak256("AAVE_V4");
    string internal constant LIQUIDATION_LOGIC_FQN =
        "dependencies/aave-v4-a3ef63e/src/spoke/libraries/LiquidationLogic.sol:LiquidationLogic";
    uint8 internal constant ORACLE_DECIMALS = 8;

    address internal aaveDao;
    address internal accessManager;
    address internal roles;
    AaveV4Bootstrap internal boot;
    bytes32 internal baseSalt;

    address internal hubCfg;
    address internal spokeCfg;
    address internal treasury;
    address internal liquidationLogic;
    address internal firstSpokeImpl;
    string internal hubsJson;
    string internal spokesJson;

    function run() external {
        string memory network = _network();
        require(block.chainid != 1 && block.chainid != 8453, "Aave V4 on Ethereum and Base is the Aave DAO's");
        string memory cfg = vm.readFile(string.concat(vm.projectRoot(), "/script/deploy/config/", network, ".json"));
        aaveDao = _addr(cfg, ".aaveLocal.aaveDao");
        require(SAFE_SINGLETON_FACTORY.code.length != 0, "Safe Singleton Factory missing: run 00_Factories");

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        baseSalt = bytes32(bytes20(sender)) | (keccak256(abi.encode(AAVE_V4_SALT, keccak256(bytes(network)))) >> 160);
        _authorityAndConfigurators();
        string[] memory hubs = vm.parseJsonStringArray(cfg, ".aaveLocal.hubs");
        for (uint256 i = 0; i < hubs.length; ++i) {
            hubsJson = _deployHub(hubs[i]);
        }
        _spokes(cfg);
        _roles(abi.encodeCall(IAaveV4Roles.grantHubRoles, (accessManager, hubCfg, aaveDao, aaveDao)));
        _roles(abi.encodeCall(IAaveV4Roles.grantSpokeRoles, (accessManager, spokeCfg, aaveDao, aaveDao)));
        _roles(abi.encodeCall(IAaveV4Roles.replaceDefaultAdminRole, (accessManager, aaveDao, address(boot))));
        vm.stopBroadcast();
        _write(network);
    }

    function _authorityAndConfigurators() private {
        liquidationLogic = _liquidationLogic();
        roles = _deploy("AvanaAaveV4Roles", _artifactIn("out-aave", "AvanaAaveV4Roles.sol", "AvanaAaveV4Roles"));
        boot = new AaveV4Bootstrap();
        accessManager = IAuthorityBatch(_batch("AaveV4AuthorityBatch", abi.encode(address(boot), baseSalt))).getReport();
        _roles(abi.encodeCall(IAaveV4Roles.labelAllRoles, (accessManager)));
        (hubCfg, spokeCfg) = IConfiguratorBatch(
                _batch("AaveV4ConfiguratorBatch", abi.encode(accessManager, accessManager, baseSalt))
            )
            .getReport();
        _roles(abi.encodeCall(IAaveV4Roles.setupConfigurators, (accessManager, hubCfg, spokeCfg)));
        treasury = ITreasurySpokeBatch(_batch("AaveV4TreasurySpokeBatch", abi.encode(aaveDao, baseSalt))).getReport();
    }

    function _spokes(
        string memory cfg
    ) private {
        bytes memory spokeCode = _linkedSpokeInstanceCode(liquidationLogic);
        uint256 n = _count(cfg, ".aaveLocal.spokes");
        for (uint256 i = 0; i < n; ++i) {
            string memory k = string.concat(".aaveLocal.spokes[", vm.toString(i), "]");
            address impl;
            (spokesJson, impl) = _deploySpoke(
                spokeCode,
                vm.parseJsonString(cfg, string.concat(k, ".label")),
                uint16(vm.parseJsonUint(cfg, string.concat(k, ".userReservesLimit")))
            );
            if (i == 0) firstSpokeImpl = impl;
        }
    }

    function _write(
        string memory network
    ) private {
        string memory o = "aave";
        vm.serializeAddress(o, "accessManager", accessManager);
        vm.serializeAddress(o, "hubConfigurator", hubCfg);
        vm.serializeAddress(o, "spokeConfigurator", spokeCfg);
        vm.serializeAddress(o, "treasurySpoke", treasury);
        vm.serializeAddress(o, "liquidationLogic", liquidationLogic);
        vm.serializeAddress(o, "aaveDao", aaveDao);
        vm.serializeAddress(o, "standardSpokeImplementation", firstSpokeImpl);
        vm.serializeString(o, "hubs", hubsJson);
        string memory json = vm.serializeString(o, "spokes", spokesJson);
        vm.createDir(string.concat(vm.projectRoot(), "/", OUTPUT_DIR, "/", network), true);
        vm.writeJson(json, _outputPath("aave"));
        console2.log("Aave V4 output", _outputPath("aave"));
    }

    function _deployHub(
        string memory label
    ) private returns (string memory json) {
        (address hub, address impl, address ir) = IHubInstanceBatch(
                _batch(
                    "AaveV4HubInstanceBatch",
                    abi.encode(
                        aaveDao,
                        accessManager,
                        _artifactIn("out-aave", "HubInstance.sol", "HubInstance"),
                        keccak256(abi.encode(baseSalt, "hub", label))
                    )
                )
            )
            .getReport();
        _roles(abi.encodeCall(IAaveV4Roles.setupHub, (accessManager, hub)));
        vm.serializeAddress(label, "proxy", hub);
        vm.serializeAddress(label, "implementation", impl);
        string memory one = vm.serializeAddress(label, "irStrategy", ir);
        json = vm.serializeString("aave.hubs", label, one);
    }

    function _deploySpoke(
        bytes memory spokeCode,
        string memory label,
        uint16 userReservesLimit
    ) private returns (string memory json, address impl) {
        address spoke;
        address oracle;
        (spoke, impl, oracle) = ISpokeInstanceBatch(
                _batch(
                    "AaveV4SpokeInstanceBatch",
                    abi.encode(
                        aaveDao,
                        accessManager,
                        spokeCode,
                        ORACLE_DECIMALS,
                        userReservesLimit,
                        keccak256(abi.encode(baseSalt, "spoke", label))
                    )
                )
            )
            .getReport();
        _roles(abi.encodeCall(IAaveV4Roles.setupSpoke, (accessManager, spoke)));
        string memory k = string.concat("spoke.", label);
        vm.serializeAddress(k, "proxy", spoke);
        vm.serializeAddress(k, "implementation", impl);
        string memory one = vm.serializeAddress(k, "oracle", oracle);
        json = vm.serializeString("aave.spokes", label, one);
    }

    function _batch(
        string memory name,
        bytes memory args
    ) private returns (address) {
        return _deploy(name, bytes.concat(_artifactIn("out-aave", string.concat(name, ".sol"), name), args));
    }

    function _roles(
        bytes memory call
    ) private {
        boot.run(roles, call);
    }

    /// @notice `LiquidationLogic` at its CREATE2 address (salt 0, Safe Singleton Factory), deployed once per network.
    function _liquidationLogic() private returns (address lib) {
        bytes memory initCode = _artifactIn("out-aave", "LiquidationLogic.sol", "LiquidationLogic");
        lib = address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), SAFE_SINGLETON_FACTORY, bytes32(0), keccak256(initCode)))
                )
            )
        );
        if (lib.code.length > 0) return lib;
        (bool ok, bytes memory ret) = SAFE_SINGLETON_FACTORY.call(abi.encodePacked(bytes32(0), initCode));
        require(ok && address(bytes20(ret)) == lib, "LiquidationLogic");
    }

    /// @notice `SpokeInstance` creation code with its `LiquidationLogic` placeholder linked to `lib`.
    function _linkedSpokeInstanceCode(
        address lib
    ) private view returns (bytes memory) {
        string memory json =
            vm.readFile(string.concat(vm.projectRoot(), "/out-aave/SpokeInstance.sol/SpokeInstance.json"));
        string memory code = vm.parseJsonString(json, ".bytecode.object");
        string memory h = vm.toString(keccak256(bytes(LIQUIDATION_LOGIC_FQN)));
        string memory placeholder = string.concat("__$", _sub(h, 2, 36), "$__");
        require(vm.indexOf(code, placeholder) != type(uint256).max, "SpokeInstance has no LiquidationLogic link");
        return vm.parseBytes(vm.replace(code, placeholder, _sub(vm.toString(lib), 2, 42)));
    }

    function _sub(
        string memory s,
        uint256 a,
        uint256 b
    ) private pure returns (string memory) {
        bytes memory x = bytes(s);
        bytes memory out = new bytes(b - a);
        for (uint256 i = a; i < b; ++i) {
            out[i - a] = x[i];
        }
        return string(out);
    }
}
