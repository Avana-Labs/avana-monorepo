// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaTest} from "../AvanaTest.sol";

/// @notice Report getters of the pinned Aave V4 deployment batches (ABI of `BatchReports` at a3ef63e).
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

/// @notice The role procedures runner compiled by the `aave` profile (`aave-deploy/AvanaAaveV4Roles.sol`).
interface IAvanaAaveV4Roles {
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
    function grantHubRole(
        address accessManager,
        uint64 role,
        address account
    ) external;
    function replaceDefaultAdminRole(
        address accessManager,
        address adminToAdd,
        address adminToRemove
    ) external;
}

/// @title AaveV4Fixture
/// @notice Deploys Avana's own Aave V4 from the pinned release (TEST-002): the AccessManager, the HubConfigurator and
/// SpokeConfigurator, the TreasurySpoke, the Stable LP Hub with its interest-rate strategy, the standard CDP Spoke
/// "Uniswap v3 Stable" and the Lend Spoke, each Spoke with its own 8-decimal AaveOracle, and `LiquidationLogic` at its
/// CREATE2 address.
/// @dev Follows Aave's deploy orchestration step for step (`AaveV4DeployOrchestration.deployAaveV4` at a3ef63e) with
/// the batch contracts built by the `aave` profile into `out-aave/`, so the code path is the one an operator runs and
/// the runtime code is the release's. Nothing here imports Aave sources: artifacts are loaded with `deployCode` and
/// `vm.getCode`, and Aave's role procedures run unchanged through `AvanaAaveV4Roles` by `delegatecall`, so the
/// AccessManager sees the fixture as the deployer, as the orchestration's deployer is. Roles end where the
/// orchestration with `grantRoles = true` leaves them, with `aaveDao` as Hub admin, Spoke admin, both configurator
/// admins, proxy admin owner and AccessManager admin; the fixture renounces its admin role.
/// Debt reserves, credit lines, First-Loss Reserves and vault-token reserves are added by later fixtures.
abstract contract AaveV4Fixture is AvanaTest {
    /// @notice Safe Singleton Factory, the CREATE2 factory of Aave's `Create2Utils`.
    address internal constant SAFE_SINGLETON_FACTORY = 0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7;

    /// @notice Runtime code of the Safe Singleton Factory (identical to the deterministic-deployment proxy): calldata is
    /// `salt ‖ initcode`, the return data is the 20-byte address.
    bytes internal constant SAFE_SINGLETON_FACTORY_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    /// @notice Salt of Aave's orchestration (`AaveV4DeployOrchestration.SALT`).
    bytes32 internal constant AAVE_V4_SALT = keccak256("AAVE_V4");

    /// @notice Root salt of the fixture; every instance salt derives from it, so addresses repeat across runs.
    bytes32 internal constant FIXTURE_SALT = keccak256("avana.fixture.aave-v4");

    /// @notice Fully qualified name of the external library `SpokeInstance` links.
    string internal constant LIQUIDATION_LOGIC_FQN =
        "dependencies/aave-v4-a3ef63e/src/spoke/libraries/LiquidationLogic.sol:LiquidationLogic";

    /// @notice Aave Hub role of a First-Loss Reserve (`Roles.HUB_DEFICIT_ELIMINATOR_ROLE`).
    uint64 internal constant HUB_DEFICIT_ELIMINATOR_ROLE = 103;

    /// @notice Labels of the instances, as Aave's orchestration names them.
    string internal constant HUB_STABLE_LP = "stable-lp";
    string internal constant SPOKE_CDP_UNISWAP_V3_STABLE = "uniswap-v3-stable";
    string internal constant SPOKE_LEND = "lend";

    /// @notice Reserves per account on the CDP Spoke: the one collateral reserve and the three debt reserves of the
    /// multi-asset fixture (GHO, USDC, WETH). The Aave DAO sets the deployed value.
    uint16 internal constant CDP_SPOKE_USER_RESERVES_LIMIT = 4;

    /// @notice Aave's default for Spokes without a limit (`DeployConstants.MAX_ALLOWED_USER_RESERVES_LIMIT`).
    uint16 internal constant DEFAULT_USER_RESERVES_LIMIT = type(uint16).max;

    /// @notice Decimals of every AaveOracle (`DeployConstants.ORACLE_DECIMALS`).
    uint8 internal constant ORACLE_DECIMALS = 8;

    struct AaveV4Deployment {
        address accessManager;
        address hubConfigurator;
        address spokeConfigurator;
        address treasurySpoke;
        address hub;
        address hubImplementation;
        address irStrategy;
        address cdpSpoke;
        address cdpSpokeImplementation;
        address cdpOracle;
        address lendSpoke;
        address lendSpokeImplementation;
        address lendOracle;
        address liquidationLogic;
        address roles;
        bytes32 salt;
    }

    AaveV4Deployment internal aave;

    /// @notice Deploys the Aave V4 stack and hands every Aave role to `aaveDao`.
    function _deployAaveV4() internal {
        _ensureCreate2Factory();
        aave.liquidationLogic = _deployLiquidationLogic();
        aave.salt = _deriveSalt(address(this), FIXTURE_SALT);
        aave.roles = deployCode("out-aave/AvanaAaveV4Roles.sol/AvanaAaveV4Roles.json");

        // Authority, with the fixture as the initial AccessManager admin.
        address authority = deployCode(
            "out-aave/AaveV4AuthorityBatch.sol/AaveV4AuthorityBatch.json", abi.encode(address(this), aave.salt)
        );
        aave.accessManager = IAuthorityBatch(authority).getReport();
        _roles(abi.encodeCall(IAvanaAaveV4Roles.labelAllRoles, (aave.accessManager)));

        // Configurators, governed by the AccessManager.
        address configurators = deployCode(
            "out-aave/AaveV4ConfiguratorBatch.sol/AaveV4ConfiguratorBatch.json",
            abi.encode(aave.accessManager, aave.accessManager, aave.salt)
        );
        (aave.hubConfigurator, aave.spokeConfigurator) = IConfiguratorBatch(configurators).getReport();
        _roles(
            abi.encodeCall(
                IAvanaAaveV4Roles.setupConfigurators, (aave.accessManager, aave.hubConfigurator, aave.spokeConfigurator)
            )
        );

        // TreasurySpoke: the fee receiver of every Hub asset, owned by the DAO.
        address treasury = deployCode(
            "out-aave/AaveV4TreasurySpokeBatch.sol/AaveV4TreasurySpokeBatch.json", abi.encode(aaveDao, aave.salt)
        );
        aave.treasurySpoke = ITreasurySpokeBatch(treasury).getReport();

        // The Stable LP Hub.
        address hubBatch = deployCode(
            "out-aave/AaveV4HubInstanceBatch.sol/AaveV4HubInstanceBatch.json",
            abi.encode(
                aaveDao,
                aave.accessManager,
                vm.getCode("out-aave/HubInstance.sol/HubInstance.json"),
                _childSalt(aave.salt, "hub", HUB_STABLE_LP)
            )
        );
        (aave.hub, aave.hubImplementation, aave.irStrategy) = IHubInstanceBatch(hubBatch).getReport();
        _roles(abi.encodeCall(IAvanaAaveV4Roles.setupHub, (aave.accessManager, aave.hub)));

        // The standard CDP Spoke and the Lend Spoke, each with its own AaveOracle.
        bytes memory spokeCode = _linkedSpokeInstanceCode(aave.liquidationLogic);
        (aave.cdpSpoke, aave.cdpSpokeImplementation, aave.cdpOracle) =
            _deploySpoke(spokeCode, SPOKE_CDP_UNISWAP_V3_STABLE, CDP_SPOKE_USER_RESERVES_LIMIT);
        (aave.lendSpoke, aave.lendSpokeImplementation, aave.lendOracle) =
            _deploySpoke(spokeCode, SPOKE_LEND, DEFAULT_USER_RESERVES_LIMIT);

        // Grants as with `grantRoles = true`, then the admin handover.
        _roles(
            abi.encodeCall(
                IAvanaAaveV4Roles.grantHubRoles, (aave.accessManager, aave.hubConfigurator, aaveDao, aaveDao)
            )
        );
        _roles(
            abi.encodeCall(
                IAvanaAaveV4Roles.grantSpokeRoles, (aave.accessManager, aave.spokeConfigurator, aaveDao, aaveDao)
            )
        );
        _roles(abi.encodeCall(IAvanaAaveV4Roles.replaceDefaultAdminRole, (aave.accessManager, aaveDao, address(this))));

        _labelAaveV4();
    }

    /// @notice Grants `HUB_DEFICIT_ELIMINATOR_ROLE` to a First-Loss Reserve, as the DAO's listing payload does.
    function _grantDeficitEliminator(
        address firstLossReserve
    ) internal {
        vm.prank(aaveDao);
        (bool ok, bytes memory data) = aave.accessManager
            .call(
                abi.encodeWithSignature(
                    "grantRole(uint64,address,uint32)", HUB_DEFICIT_ELIMINATOR_ROLE, firstLossReserve, 0
                )
            );
        _bubble(ok, data);
    }

    // ─── Steps ───

    function _deploySpoke(
        bytes memory spokeCode,
        string memory label,
        uint16 userReservesLimit
    ) private returns (address spoke, address implementation, address oracle) {
        address batch = deployCode(
            "out-aave/AaveV4SpokeInstanceBatch.sol/AaveV4SpokeInstanceBatch.json",
            abi.encode(
                aaveDao,
                aave.accessManager,
                spokeCode,
                ORACLE_DECIMALS,
                userReservesLimit,
                _childSalt(aave.salt, "spoke", label)
            )
        );
        (spoke, implementation, oracle) = ISpokeInstanceBatch(batch).getReport();
        _roles(abi.encodeCall(IAvanaAaveV4Roles.setupSpoke, (aave.accessManager, spoke)));
    }

    /// @notice Etches the Safe Singleton Factory where it has no code (local runs); forks and Sepolia already have it.
    function _ensureCreate2Factory() internal {
        if (SAFE_SINGLETON_FACTORY.code.length == 0) vm.etch(SAFE_SINGLETON_FACTORY, SAFE_SINGLETON_FACTORY_CODE);
    }

    /// @notice CREATE2-deploys `LiquidationLogic` with salt 0 through the factory, or returns the existing deployment.
    function _deployLiquidationLogic() internal returns (address library_) {
        bytes memory initCode = vm.getCode("out-aave/LiquidationLogic.sol/LiquidationLogic.json");
        library_ = address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), SAFE_SINGLETON_FACTORY, bytes32(0), keccak256(initCode)))
                )
            )
        );
        if (library_.code.length > 0) return library_;
        (bool ok, bytes memory data) = SAFE_SINGLETON_FACTORY.call(abi.encodePacked(bytes32(0), initCode));
        _bubble(ok, data);
        require(address(bytes20(data)) == library_, "LiquidationLogic address");
    }

    /// @notice `SpokeInstance` creation code with every `LiquidationLogic` placeholder replaced by `library_`.
    function _linkedSpokeInstanceCode(
        address library_
    ) internal view returns (bytes memory) {
        string memory json =
            vm.readFile(string.concat(vm.projectRoot(), "/out-aave/SpokeInstance.sol/SpokeInstance.json"));
        string memory code = vm.parseJsonString(json, ".bytecode.object");
        string memory placeholder = _placeholder(LIQUIDATION_LOGIC_FQN);
        require(vm.indexOf(code, placeholder) != type(uint256).max, "SpokeInstance has no LiquidationLogic link");
        string memory addressHex = _slice(vm.toString(library_), 2, 42);
        return vm.parseBytes(vm.replace(code, placeholder, addressHex));
    }

    // ─── Salts (AaveV4DeployOrchestration._deriveSalt / _deriveChildSalt) ───

    function _deriveSalt(
        address deployer,
        bytes32 salt
    ) internal pure returns (bytes32) {
        return bytes32(bytes20(deployer)) | (keccak256(abi.encode(AAVE_V4_SALT, salt)) >> 160);
    }

    function _childSalt(
        bytes32 baseSalt,
        string memory contractType,
        string memory label
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(baseSalt, contractType, label));
    }

    // ─── Utilities ───

    function _roles(
        bytes memory call
    ) private {
        (bool ok, bytes memory data) = aave.roles.delegatecall(call);
        _bubble(ok, data);
    }

    /// @notice Solidity library placeholder `__$<first 34 hex of keccak256(fqn)>$__`.
    function _placeholder(
        string memory fqn
    ) internal pure returns (string memory) {
        return string.concat("__$", _slice(vm.toString(keccak256(bytes(fqn))), 2, 36), "$__");
    }

    function _slice(
        string memory s,
        uint256 start,
        uint256 end
    ) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(end - start);
        for (uint256 i = start; i < end; ++i) {
            out[i - start] = b[i];
        }
        return string(out);
    }

    function _bubble(
        bool ok,
        bytes memory data
    ) internal pure {
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(data, 0x20), mload(data))
            }
        }
    }

    function _labelAaveV4() private {
        vm.label(aave.accessManager, "Aave.AccessManager");
        vm.label(aave.hubConfigurator, "Aave.HubConfigurator");
        vm.label(aave.spokeConfigurator, "Aave.SpokeConfigurator");
        vm.label(aave.treasurySpoke, "Aave.TreasurySpoke");
        vm.label(aave.hub, "Aave.Hub.StableLP");
        vm.label(aave.irStrategy, "Aave.IRStrategy.StableLP");
        vm.label(aave.cdpSpoke, "Aave.Spoke.UniswapV3Stable");
        vm.label(aave.cdpOracle, "Aave.Oracle.UniswapV3Stable");
        vm.label(aave.lendSpoke, "Aave.Spoke.Lend");
        vm.label(aave.lendOracle, "Aave.Oracle.Lend");
        vm.label(aave.liquidationLogic, "Aave.LiquidationLogic");
        vm.label(SAFE_SINGLETON_FACTORY, "SafeSingletonFactory");
    }
}
