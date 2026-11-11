// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4ExtSload} from "../../src/interfaces/external/aave/IAaveV4ExtSload.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {SpokeDef} from "../../src/policy/market-registry/types/SpokeDef.sol";
import {DriftReason} from "../../src/types/DriftReason.sol";
import {AaveV4Fixture} from "../utils/fixtures/AaveV4Fixture.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryLPVaultMock} from "../utils/mocks/MarketRegistryMocks.sol";

interface ISpokeInstanceBatchReport {
    function getReport() external view returns (address spoke, address implementation, address oracle);
}

interface IProxyAdminUpgrade {
    function upgradeAndCall(
        address proxy,
        address implementation,
        bytes calldata data
    ) external payable;
}

/// @notice `deployCdpSpoke` against the real, unmodified Aave V4 Spoke and AaveOracle of the local fixture.
contract MarketRegistryAaveSpokeUnitTest is MarketRegistryFixture, AaveV4Fixture {
    /// @dev ERC-1967 admin slot of the Spoke's TransparentUpgradeableProxy (its ProxyAdmin, owned by the Aave DAO).
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    uint32 internal constant SLIP = 2;

    function setUp() public {
        _deployAaveV4();
        _deployRegistryWith(aave.cdpSpokeImplementation);
        lpVault = new RegistryLPVaultMock(V3, address(collat), lockAddr);
        lpVault.setRegistry(address(registry));
        vm.prank(address(timelock));
        factory.registerIntegration(V3, address(lpVault));
        vm.startPrank(address(timelock));
        registry.recordHub(aave.hub, RiskTier.Stable);
        registry.registerIntegration(V3, address(lpVault), makeAddr("clPricing"));
        vm.stopPrank();
    }

    function _def(
        address implementation
    ) internal view returns (SpokeDef memory) {
        return SpokeDef(false, aave.hub, V3, RiskTier.Stable, implementation, aave.cdpOracle);
    }

    // TEST-182 verifies: REQ-CONFIG-074, REQ-CONFIG-077, REQ-CONFIG-016, ATTACK-121, Q-281, Q-309
    // Sources: 5.1 TEST-182, TEST-185
    function test_TEST_182_recordsTheRealStandardSpoke() public {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        assertEq(address(uint160(uint256(IAaveV4ExtSload(aave.cdpSpoke).extSload(slot)))), aave.cdpSpokeImplementation);
        // The Lend Spoke's implementation is another deployment of the same audited code, but not this Spoke's.
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.InvalidSpoke.selector, aave.cdpSpoke));
        registry.deployCdpSpoke(_def(aave.lendSpokeImplementation));
        vm.prank(address(timelock));
        address s = registry.deployCdpSpoke(_def(aave.cdpSpokeImplementation));
        assertEq(s, aave.cdpSpoke);
        assertEq(registry.getSpoke(s).aaveOracle, aave.cdpOracle);
        (, DriftReason r) = registry.spokeSettingsDrift(s);
        assertEq(uint8(r), uint8(DriftReason.None));
    }

    /// @dev A second CDP Spoke from the same audited `SpokeInstance` code with its own AaveOracle, as the Aave payload
    /// deploys it, and a second integration for it to serve (one Spoke per Hub, integration and tier).
    function _secondSpoke() internal returns (address spoke2, address impl2, address oracle2) {
        address batch = deployCode(
            "out-aave/AaveV4SpokeInstanceBatch.sol/AaveV4SpokeInstanceBatch.json",
            abi.encode(
                aaveDao,
                aave.accessManager,
                _linkedSpokeInstanceCode(aave.liquidationLogic),
                ORACLE_DECIMALS,
                CDP_SPOKE_USER_RESERVES_LIMIT,
                _childSalt(aave.salt, "spoke", "slipstream-stable")
            )
        );
        (spoke2, impl2, oracle2) = ISpokeInstanceBatchReport(batch).getReport();
        RegistryLPVaultMock lpVault2 = new RegistryLPVaultMock(SLIP, address(collat), lockAddr);
        lpVault2.setRegistry(address(registry));
        vm.startPrank(address(timelock));
        factory.registerIntegration(SLIP, address(lpVault2));
        registry.registerIntegration(SLIP, address(lpVault2), makeAddr("slipPricing"));
        vm.stopPrank();
    }

    /// @dev A new `SpokeInstance` implementation built with `oracle` and the CDP Spoke's user-reserve limit.
    function _newImplementation(
        address oracle
    ) internal returns (address impl) {
        bytes memory init = abi.encodePacked(
            _linkedSpokeInstanceCode(aave.liquidationLogic), abi.encode(oracle, CDP_SPOKE_USER_RESERVES_LIMIT)
        );
        // Reason: deploys raw creation code with appended constructor arguments, as the Aave payload does.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            impl := create(0, add(init, 0x20), mload(init))
        }
        assertTrue(impl != address(0), "SpokeInstance deployment");
    }

    // TEST-185 verifies: REQ-CONFIG-074, REQ-CONFIG-077, REQ-CONFIG-016, ATTACK-121
    // Sources: MarketRegistry review 2026-11-10 finding 1 (two real Spokes)
    function test_TEST_185_twoRealCdpSpokes() public {
        vm.prank(address(timelock));
        registry.deployCdpSpoke(_def(aave.cdpSpokeImplementation));
        (address spoke2, address impl2, address oracle2) = _secondSpoke();
        // Same audited code and limit, another oracle: the immutables make another code hash.
        assertTrue(impl2.codehash != aave.cdpSpokeImplementation.codehash);
        SpokeDef memory d2 = SpokeDef(false, aave.hub, SLIP, RiskTier.Stable, impl2, oracle2);
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.InvalidSpoke.selector, spoke2));
        registry.deployCdpSpoke(d2);
        // Governance approves the reviewed hash at the normal delay; the same batch records the Spoke.
        vm.startPrank(address(timelock));
        registry.approveSpokeCodeHash(impl2.codehash);
        assertEq(registry.deployCdpSpoke(d2), spoke2);
        vm.stopPrank();
        (address i1,, bool c1) = registry.spokeImplementationStatus(aave.cdpSpoke);
        (address i2, bytes32 h2, bool c2) = registry.spokeImplementationStatus(spoke2);
        assertEq(i1, aave.cdpSpokeImplementation);
        assertEq(i2, impl2);
        assertEq(h2, impl2.codehash);
        assertTrue(c1 && c2);
        assertEq(registry.getSpokes().length, 2);
    }

    // TEST-185 verifies: REQ-CONFIG-074, REQ-CONFIG-016, REQ-CONFIG-076
    // Sources: Step 2 decisions 2026-11-11 (the check binds the implementation behind the proxy, not the proxy's code)
    function test_TEST_185_realProxyUpgradeNeedsReapproval() public {
        vm.prank(address(timelock));
        address s = registry.deployCdpSpoke(_def(aave.cdpSpokeImplementation));
        bytes32 proxyCodeHash = s.codehash;
        // The Aave DAO upgrades the Spoke proxy through its ProxyAdmin to a fresh deployment of the same code with the
        // same oracle; the EIP-712 domain cache embeds each deployment's own address, so even it has a new hash.
        address upgraded = _newImplementation(aave.cdpOracle);
        assertTrue(upgraded.codehash != aave.cdpSpokeImplementation.codehash);
        address proxyAdmin = address(uint160(uint256(vm.load(s, ADMIN_SLOT))));
        vm.prank(aaveDao);
        IProxyAdminUpgrade(proxyAdmin).upgradeAndCall(s, upgraded, "");
        // The proxy's own code is unchanged; the implementation behind it is not.
        assertEq(s.codehash, proxyCodeHash);
        (address impl, bytes32 h, bool current) = registry.spokeImplementationStatus(s);
        assertEq(impl, upgraded);
        assertEq(h, upgraded.codehash);
        assertFalse(current);
        (, DriftReason r) = registry.spokeSettingsDrift(s);
        assertEq(uint8(r), uint8(DriftReason.SpokeImplementation));
        // Re-approval needs the new hash approved first; one batch runs both.
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.InvalidSpoke.selector, s));
        registry.deployCdpSpoke(_def(upgraded));
        vm.startPrank(address(timelock));
        registry.approveSpokeCodeHash(upgraded.codehash);
        registry.deployCdpSpoke(_def(upgraded));
        vm.stopPrank();
        (,, current) = registry.spokeImplementationStatus(s);
        assertTrue(current);
        (, r) = registry.spokeSettingsDrift(s);
        assertEq(uint8(r), uint8(DriftReason.None));
    }

    // TEST-182 verifies: REQ-CONFIG-074, REQ-CONFIG-016
    function test_TEST_182_oracleOfAnotherSpokeIsRefused() public {
        SpokeDef memory d = _def(aave.cdpSpokeImplementation);
        d.aaveOracle = aave.lendOracle;
        // The Lend Spoke's oracle names the Lend Spoke, whose implementation is not `d.implementation`.
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.InvalidSpoke.selector, aave.lendSpoke));
        registry.deployCdpSpoke(d);
    }
}
