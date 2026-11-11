// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../src/interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {Deployments} from "../utils/Deployments.sol";

interface IAccessManagerView {
    function hasRole(
        uint64 roleId,
        address account
    ) external view returns (bool isMember, uint32 executionDelay);
    function getTargetFunctionRole(
        address target,
        bytes4 selector
    ) external view returns (uint64);
}

interface IAccessManagedView {
    function authority() external view returns (address);
}

/// @title AaveV4FixtureUnitTest
/// @notice The local Aave V4 deployment every Avana suite runs on: the pinned release deployed by Aave's own batches
/// and role procedures, `LiquidationLogic` at its CREATE2 address, and every Aave role with the DAO.
/// @dev First part of TEST-002 (Hub, CDP Spoke, Lend Spoke, AaveOracle, configurators, library link). The Coverage
/// Spokes, debt reserves and vault-token reserves are added to the fixture with the contracts that need them, and their
/// checks join this row then.
contract AaveV4FixtureUnitTest is Deployments {
    function setUp() public {
        _deployAaveV4();
    }

    // TEST-002 verifies: Q-043, Q-044, Q-074, Q-119
    // Sources: 5.1 TEST-002, contracts/test/README.md 3.1
    function test_TEST_002_deploysHubAndSpokesWithOwnOracles() public view {
        assertGt(aave.hub.code.length, 0, "hub");
        assertGt(aave.cdpSpoke.code.length, 0, "cdp spoke");
        assertGt(aave.lendSpoke.code.length, 0, "lend spoke");
        assertNotEq(aave.cdpOracle, aave.lendOracle, "one AaveOracle per Spoke");
        assertEq(IAaveV4Spoke(aave.cdpSpoke).ORACLE(), aave.cdpOracle, "cdp oracle");
        assertEq(IAaveV4Spoke(aave.lendSpoke).ORACLE(), aave.lendOracle, "lend oracle");
        assertEq(IAaveV4Oracle(aave.cdpOracle).decimals(), ORACLE_DECIMALS, "oracle decimals");
        assertEq(IAaveV4Spoke(aave.cdpSpoke).MAX_USER_RESERVES_LIMIT(), CDP_SPOKE_USER_RESERVES_LIMIT, "limit");
        assertEq(IAaveV4Hub(aave.hub).getSpokeCount(0), 0, "no asset listed yet");
    }

    // TEST-002 verifies: Q-043, Q-074, Q-119
    function test_TEST_002_spokeLinksLiquidationLogicAtCreate2Address() public view {
        bytes memory initCode = vm.getCode("out-aave/LiquidationLogic.sol/LiquidationLogic.json");
        address expected = address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), SAFE_SINGLETON_FACTORY, bytes32(0), keccak256(initCode)))
                )
            )
        );
        assertEq(aave.liquidationLogic, expected, "library address");
        assertGt(expected.code.length, 0, "library deployed");
        string memory runtime = vm.toString(aave.cdpSpokeImplementation.code);
        string memory needle = vm.toLowercase(_slice(vm.toString(expected), 2, 42));
        assertTrue(vm.indexOf(runtime, needle) != type(uint256).max, "SpokeInstance calls the CREATE2 library");
    }

    // TEST-002 verifies: Q-043, Q-074, Q-119
    function test_TEST_002_runtimeCodeIsTheRelease() public view {
        assertEq(
            keccak256(aave.hubImplementation.code),
            keccak256(vm.getDeployedCode("out-aave/HubInstance.sol/HubInstance.json")),
            "HubInstance runtime"
        );
        // A library's runtime starts with PUSH20 of its own address; the rest is the release's code.
        bytes memory built = vm.getDeployedCode("out-aave/LiquidationLogic.sol/LiquidationLogic.json");
        bytes memory deployed = aave.liquidationLogic.code;
        assertEq(deployed.length, built.length, "LiquidationLogic length");
        assertEq(keccak256(_tail(deployed, 21)), keccak256(_tail(built, 21)), "LiquidationLogic runtime");
    }

    // TEST-002 verifies: Q-043, Q-044, Q-119
    function test_TEST_002_rolesEndWithTheDao() public view {
        IAccessManagerView am = IAccessManagerView(aave.accessManager);
        (bool daoAdmin,) = am.hasRole(0, aaveDao);
        (bool fixtureAdmin,) = am.hasRole(0, address(this));
        assertTrue(daoAdmin, "DAO is AccessManager admin");
        assertFalse(fixtureAdmin, "fixture renounced");
        (bool configurator,) = am.hasRole(101, aave.hubConfigurator);
        assertTrue(configurator, "HubConfigurator holds HUB_CONFIGURATOR_ROLE");
        (bool spokeConfigurator,) = am.hasRole(301, aave.spokeConfigurator);
        assertTrue(spokeConfigurator, "SpokeConfigurator holds SPOKE_CONFIGURATOR_ROLE");
        assertEq(
            am.getTargetFunctionRole(aave.hub, IAaveV4Hub.eliminateDeficit.selector),
            HUB_DEFICIT_ELIMINATOR_ROLE,
            "eliminateDeficit is the deficit eliminator's"
        );
        assertEq(IAccessManagedView(aave.hub).authority(), aave.accessManager, "hub authority");
        assertEq(IAccessManagedView(aave.cdpSpoke).authority(), aave.accessManager, "spoke authority");
    }

    // TEST-002 verifies: Q-043, Q-119
    function test_TEST_002_strangerCannotEliminateDeficit() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", attacker));
        IAaveV4Hub(aave.hub).eliminateDeficit(0, 1, aave.cdpSpoke);
    }

    // TEST-004 verifies: Q-043, Q-074
    // Sources: 5.1 TEST-004 (manifest write and read; the shared fork environment comes with the deploy script)
    function test_TEST_004_manifestRoundTripsAaveSection() public {
        string memory path = _writeManifest("fixture-test");
        assertEq(_readManifestAddress(path, ".aave.accessManager"), aave.accessManager, "accessManager");
        assertEq(_readManifestAddress(path, ".aave['hub.stable-lp']"), aave.hub, "hub");
        assertEq(_readManifestAddress(path, ".aave['spoke.uniswap-v3-stable']"), aave.cdpSpoke, "cdp spoke");
        assertEq(_readManifestAddress(path, ".aave.liquidationLogic"), aave.liquidationLogic, "library");
        vm.removeFile(path);
    }

    function _tail(
        bytes memory b,
        uint256 from
    ) private pure returns (bytes memory out) {
        out = new bytes(b.length - from);
        for (uint256 i = from; i < b.length; ++i) {
            out[i - from] = b[i];
        }
    }
}
