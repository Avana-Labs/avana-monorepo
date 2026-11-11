// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {SpokeDef} from "../../src/policy/market-registry/types/SpokeDef.sol";
import {RiskModuleDriftLogic} from "../../src/policy/risk-module/RiskModuleDriftLogic.sol";
import {RiskModuleImmutables} from "../../src/policy/risk-module/types/RiskModuleImmutables.sol";
import {IPositionProxy} from "../../src/proxy/position-proxy/IPositionProxy.sol";
import {PositionProxy} from "../../src/proxy/position-proxy/PositionProxy.sol";
import {DriftReason} from "../../src/types/DriftReason.sol";
import {AaveV4Fixture} from "../utils/fixtures/AaveV4Fixture.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryLPVaultMock} from "../utils/mocks/MarketRegistryMocks.sol";

/// @notice The position-manager surface of the pinned Aave V4 Spoke (`Spoke.sol` at a3ef63e), ABI-equal.
interface ISpokePositionManagers {
    struct PositionManagerUpdate {
        address positionManager;
        bool approve;
    }

    struct SetUserPositionManagers {
        address onBehalfOf;
        PositionManagerUpdate[] updates;
        uint256 nonce;
        uint256 deadline;
    }

    function setUserPositionManager(
        address positionManager,
        bool approve
    ) external;
    function setUserPositionManagersWithSig(
        SetUserPositionManagers calldata params,
        bytes calldata signature
    ) external;
    function renouncePositionManagerRole(
        address onBehalfOf
    ) external;
    function updatePositionManager(
        address positionManager,
        bool active
    ) external;
    function isPositionManager(
        address user,
        address positionManager
    ) external view returns (bool);
    function isPositionManagerActive(
        address positionManager
    ) external view returns (bool);
    function multicall(
        bytes[] calldata data
    ) external returns (bytes[] memory);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function nonces(
        address owner,
        uint192 key
    ) external view returns (uint256);
}

interface IProxyAdminUpgradeAndCall {
    function upgradeAndCall(
        address proxy,
        address implementation,
        bytes calldata data
    ) external payable;
}

/// @title RiskModulePositionManagersUnitTest
/// @notice Every route of the pinned Aave V4 Spoke that can approve a position manager, run against the real local
/// Spoke and a real PositionProxy: the direct call and `multicall` bind the caller, the signature route needs the
/// proxy's own signature (ERC-1271 once deployed, the key of the CREATE2 address before), renouncing only removes and
/// governance activation alone approves nothing. The proxy's `execute` forwards the Adapter's calldata to any code
/// target but itself, the Adapter and the ProxyManager, so the remaining route is the Adapter's selector set
/// (REQ-PROXY-008), which the AaveAdapter's tests check. A Spoke implementation change is drift (`SpokeImplementation`).
/// @dev The test contract plays the ProxyManager: it creates the proxy with CREATE2, so the proxy's address is known
/// before it has code.
contract RiskModulePositionManagersUnitTest is MarketRegistryFixture, AaveV4Fixture {
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant SET_USER_POSITION_MANAGERS_TYPEHASH =
        0xba01f7bf3d3674c63670ec4a78b0d56aac1ad6e8c84468920b9e61bfe0b9851a;
    bytes32 internal constant POSITION_MANAGER_UPDATE =
        0x187dbd227227274b90655fb4011fc21dd749e8966fc040bd91e0b92609202565;
    uint256 internal constant MARKET = 7;
    bytes32 internal constant SALT = keccak256("avana.test.position-proxy");

    ISpokePositionManagers internal sp;
    PositionProxy internal proxy;
    address internal adapterAddr;
    address internal walletAddr;
    uint256 internal walletKey;
    address internal manager;

    function setUp() public {
        _deployAaveV4();
        sp = ISpokePositionManagers(aave.cdpSpoke);
        adapterAddr = makeAddr("adapter");
        (walletAddr, walletKey) = makeAddrAndKey("borrowerWallet");
        manager = makeAddr("positionManager");
        proxy = new PositionProxy{salt: SALT}(adapterAddr, walletAddr, aave.cdpSpoke, MARKET);
        // Worst case: the Aave DAO has activated the manager on Avana's CDP Spoke.
        vm.prank(aaveDao);
        sp.updatePositionManager(manager, true);
        assertTrue(sp.isPositionManagerActive(manager));
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------------

    function _intent(
        address onBehalfOf,
        address pm,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (ISpokePositionManagers.SetUserPositionManagers memory p) {
        p.onBehalfOf = onBehalfOf;
        p.updates = new ISpokePositionManagers.PositionManagerUpdate[](1);
        p.updates[0] = ISpokePositionManagers.PositionManagerUpdate(pm, true);
        p.nonce = nonce;
        p.deadline = deadline;
    }

    /// @dev EIP-712 digest of the intent, as `EIP712Hash.hash` and Solady's `_hashTypedData` build it.
    function _digest(
        ISpokePositionManagers.SetUserPositionManagers memory p
    ) internal view returns (bytes32) {
        bytes32[] memory h = new bytes32[](p.updates.length);
        for (uint256 i = 0; i < h.length; ++i) {
            h[i] = keccak256(abi.encode(POSITION_MANAGER_UPDATE, p.updates[i].positionManager, p.updates[i].approve));
        }
        bytes32 structHash = keccak256(
            abi.encode(
                SET_USER_POSITION_MANAGERS_TYPEHASH, p.onBehalfOf, keccak256(abi.encodePacked(h)), p.nonce, p.deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", sp.DOMAIN_SEPARATOR(), structHash));
    }

    function _sign(
        uint256 key,
        bytes32 digest
    ) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _assertUnapproved(
        address account
    ) internal view {
        assertFalse(sp.isPositionManager(account, manager), "manager approved for the proxy");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Direct and batched approval
    // -----------------------------------------------------------------------------------------------------------------

    // TEST-172 verifies: REQ-PROXY-008, REQ-ADAPTER-006, ATTACK-030, INV-016
    function test_TEST_172_directApprovalBindsTheCaller() public {
        address[6] memory callers = [walletAddr, adapterAddr, address(this), manager, aaveDao, makeAddr("attacker")];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.prank(callers[i]);
            sp.setUserPositionManager(manager, true);
            // The approval is the caller's own; the proxy's stays unset.
            assertTrue(sp.isPositionManager(callers[i], manager));
            _assertUnapproved(address(proxy));
        }
    }

    // TEST-172 verifies: REQ-PROXY-008, ATTACK-030
    function testFuzz_TEST_172_directApprovalBindsTheCaller(
        address caller
    ) public {
        vm.assume(caller != address(proxy) && caller != address(0));
        vm.prank(caller);
        sp.setUserPositionManager(manager, true);
        _assertUnapproved(address(proxy));
    }

    // TEST-172 verifies: REQ-PROXY-008, ATTACK-030
    function test_TEST_172_multicallBindsTheCaller() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(ISpokePositionManagers.setUserPositionManager, (manager, true));
        calls[1] = abi.encodeCall(ISpokePositionManagers.renouncePositionManagerRole, (address(proxy)));
        // `multicall` delegatecalls the Spoke itself, so `msg.sender` stays the batch's caller.
        vm.prank(walletAddr);
        sp.multicall(calls);
        assertTrue(sp.isPositionManager(walletAddr, manager));
        _assertUnapproved(address(proxy));
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Signature route
    // -----------------------------------------------------------------------------------------------------------------

    // TEST-172 verifies: REQ-PROXY-008, ATTACK-030, INV-063
    function test_TEST_172_noSignatureApprovesForADeployedProxy() public {
        ISpokePositionManagers.SetUserPositionManagers memory p =
            _intent(address(proxy), manager, 0, block.timestamp + 1);
        bytes32 digest = _digest(p);
        // The proxy has code, so the Spoke asks the proxy through ERC-1271; the proxy has no such function and no
        // fallback, so the wallet's own signature, any other key's and arbitrary bytes are all refused.
        (, uint256 attackerKey) = makeAddrAndKey("attacker");
        bytes[3] memory sigs = [_sign(walletKey, digest), _sign(attackerKey, digest), bytes(hex"1271")];
        for (uint256 i = 0; i < sigs.length; ++i) {
            vm.expectRevert();
            sp.setUserPositionManagersWithSig(p, sigs[i]);
        }
        _assertUnapproved(address(proxy));
    }

    // TEST-172 verifies: REQ-PROXY-008, ATTACK-030
    function testFuzz_TEST_172_noSignatureApprovesForADeployedProxy(
        bytes calldata signature,
        uint256 nonce
    ) public {
        ISpokePositionManagers.SetUserPositionManagers memory p =
            _intent(address(proxy), manager, nonce, block.timestamp);
        vm.expectRevert();
        sp.setUserPositionManagersWithSig(p, signature);
        _assertUnapproved(address(proxy));
    }

    // TEST-172 verifies: INV-016, INV-063, ATTACK-030
    function testFuzz_TEST_172_proxyAnswersNoErc1271(
        bytes32 hash,
        bytes calldata signature,
        address caller
    ) public {
        vm.prank(caller);
        (bool ok, bytes memory ret) =
            address(proxy).staticcall(abi.encodeWithSelector(bytes4(0x1626ba7e), hash, signature));
        assertFalse(ok);
        assertEq(ret.length, 0);
    }

    // TEST-172 verifies: REQ-PROXY-008, ATTACK-030
    function testFuzz_TEST_172_beforeDeploymentOnlyTheAddressKeySigns(
        uint256 key
    ) public {
        key = bound(
            key,
            1,
            115_792_089_237_316_195_423_570_985_008_687_907_852_837_564_279_074_904_382_605_163_141_518_161_494_336
        );
        // A proxy that does not exist yet: its CREATE2 address has no code, so the Spoke recovers an ECDSA signer and
        // compares it with that address. No key of the borrower, the Adapter or anyone else recovers to it.
        bytes32 salt = keccak256("avana.test.position-proxy.next");
        address next = vm.computeCreate2Address(
            salt,
            keccak256(
                abi.encodePacked(
                    type(PositionProxy).creationCode, abi.encode(adapterAddr, walletAddr, aave.cdpSpoke, MARKET + 1)
                )
            ),
            address(this)
        );
        assertEq(next.code.length, 0);
        vm.assume(vm.addr(key) != next);
        ISpokePositionManagers.SetUserPositionManagers memory p = _intent(next, manager, 0, block.timestamp);
        bytes memory sig = _sign(key, _digest(p));
        vm.expectRevert();
        sp.setUserPositionManagersWithSig(p, sig);
        // The proxy is created afterwards with no manager approved.
        PositionProxy created = new PositionProxy{salt: salt}(adapterAddr, walletAddr, aave.cdpSpoke, MARKET + 1);
        assertEq(address(created), next);
        _assertUnapproved(next);
    }

    // TEST-172 verifies: REQ-PROXY-008, ATTACK-030
    function test_TEST_172_signatureRouteNeedsTheExactAddressKey() public {
        // The ECDSA branch authorizes exactly the holder of the key of `onBehalfOf`: an EOA approving for itself works,
        // which is why a proxy's safety before deployment rests on no key existing for its CREATE2 address.
        (address eoa, uint256 eoaKey) = makeAddrAndKey("eoaUser");
        ISpokePositionManagers.SetUserPositionManagers memory p = _intent(eoa, manager, 0, block.timestamp);
        sp.setUserPositionManagersWithSig(p, _sign(eoaKey, _digest(p)));
        assertTrue(sp.isPositionManager(eoa, manager));
        _assertUnapproved(address(proxy));
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Renounce and governance activation
    // -----------------------------------------------------------------------------------------------------------------

    // TEST-172 verifies: REQ-PROXY-008, ATTACK-030
    function test_TEST_172_renounceAndActivationApproveNothing() public {
        // Activation by the Aave DAO is per manager, not per account: the proxy's approval stays unset.
        _assertUnapproved(address(proxy));
        vm.prank(manager);
        sp.renouncePositionManagerRole(address(proxy));
        _assertUnapproved(address(proxy));
        vm.prank(aaveDao);
        sp.updatePositionManager(manager, false);
        vm.prank(aaveDao);
        sp.updatePositionManager(manager, true);
        _assertUnapproved(address(proxy));
        // The proxy is its own position manager only.
        assertTrue(sp.isPositionManager(address(proxy), address(proxy)));
    }

    // -----------------------------------------------------------------------------------------------------------------
    // The proxy's own surface
    // -----------------------------------------------------------------------------------------------------------------

    // TEST-172 verifies: INV-063, REQ-PROXY-008, ATTACK-030
    function testFuzz_TEST_172_onlyTheAdapterDrivesTheProxy(
        address caller
    ) public {
        vm.assume(caller != adapterAddr);
        bytes memory approve = abi.encodeCall(ISpokePositionManagers.setUserPositionManager, (manager, true));
        vm.prank(caller);
        vm.expectRevert(IPositionProxy.OnlyAdapter.selector);
        proxy.execute(aave.cdpSpoke, approve);
        _assertUnapproved(address(proxy));
    }

    // TEST-172 verifies: INV-016, REQ-PROXY-008, REQ-PROXY-091
    function test_TEST_172_executeTargetsAndTheAdapterSelectorSet() public {
        bytes memory approve = abi.encodeCall(ISpokePositionManagers.setUserPositionManager, (manager, true));
        address[4] memory refused = [address(proxy), address(0), adapterAddr, address(this)];
        for (uint256 i = 0; i < refused.length; ++i) {
            vm.prank(adapterAddr);
            vm.expectRevert(abi.encodeWithSelector(IPositionProxy.InvalidTarget.selector, refused[i]));
            proxy.execute(refused[i], approve);
        }
        address codeless = makeAddr("codeless");
        vm.prank(adapterAddr);
        vm.expectRevert(abi.encodeWithSelector(IPositionProxy.InvalidTarget.selector, codeless));
        proxy.execute(codeless, approve);
        // Any code target is allowed, the Spoke included, and the proxy forwards the Adapter's calldata unchanged: the
        // Adapter's fixed selector set (REQ-PROXY-008) is what keeps `setUserPositionManager` out of every Avana action.
        vm.prank(adapterAddr);
        proxy.execute(aave.cdpSpoke, approve);
        assertTrue(sp.isPositionManager(address(proxy), manager));
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Spoke implementation change
    // -----------------------------------------------------------------------------------------------------------------

    // TEST-182 verifies: REQ-ADAPTER-063, REQ-RISK-088, REQ-CONFIG-074
    // Sources: Step 2 decisions 2026-11-11 (upgrade detection binds the implementation behind the Spoke proxy)
    function test_TEST_182_realSpokeUpgradeIsDrift() public {
        _deployRegistryWith(aave.cdpSpokeImplementation);
        lpVault = new RegistryLPVaultMock(V3, address(collat), lockAddr);
        lpVault.setRegistry(address(registry));
        vm.startPrank(address(timelock));
        factory.registerIntegration(V3, address(lpVault));
        registry.recordHub(aave.hub, RiskTier.Stable);
        registry.registerIntegration(V3, address(lpVault), makeAddr("clPricing"));
        address s = registry.deployCdpSpoke(
            SpokeDef(false, aave.hub, V3, RiskTier.Stable, aave.cdpSpokeImplementation, aave.cdpOracle)
        );
        vm.stopPrank();
        (,, bool current) = registry.spokeImplementationStatus(s);
        assertTrue(current);
        RiskModuleDriftLogic drift = new RiskModuleDriftLogic(
            RiskModuleImmutables(
                address(registry), address(ps), address(collat), adapterAddr, address(lpVaultSwap), address(timelock)
            )
        );
        // The Aave DAO upgrades the Spoke proxy to a fresh deployment of the same code: the proxy's code is
        // unchanged, the implementation behind it is not, and every Avana check on the Spoke reports drift.
        bytes memory init = abi.encodePacked(
            _linkedSpokeInstanceCode(aave.liquidationLogic), abi.encode(aave.cdpOracle, CDP_SPOKE_USER_RESERVES_LIMIT)
        );
        address upgraded;
        // Reason: deploys raw creation code with appended constructor arguments, as the Aave payload does.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            upgraded := create(0, add(init, 0x20), mload(init))
        }
        address proxyAdmin = address(uint160(uint256(vm.load(s, ADMIN_SLOT))));
        bytes32 proxyCode = s.codehash;
        vm.prank(aaveDao);
        IProxyAdminUpgradeAndCall(proxyAdmin).upgradeAndCall(s, upgraded, "");
        assertEq(s.codehash, proxyCode);
        (uint256 marketId, DriftReason reason) = drift.spokeDrift(s);
        assertEq(marketId, 0);
        assertEq(uint8(reason), uint8(DriftReason.SpokeImplementation));
        uint256[] memory none = new uint256[](0);
        (marketId, reason) = drift.driftOf(s, none, address(proxy));
        assertEq(uint8(reason), uint8(DriftReason.SpokeImplementation));
        // Approval state written by an implementation is no longer trusted: the position-manager routes above must be
        // revalidated against the new implementation before governance re-approves it with `deployCdpSpoke`.
    }
}
