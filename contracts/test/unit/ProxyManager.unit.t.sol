// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IPositionProxy} from "../../src/proxy/position-proxy/IPositionProxy.sol";
import {PositionProxy} from "../../src/proxy/position-proxy/PositionProxy.sol";
import {IProxyManager} from "../../src/proxy/proxy-manager/IProxyManager.sol";
import {ProxyManager} from "../../src/proxy/proxy-manager/ProxyManager.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {BytecodeInspector} from "../utils/BytecodeInspector.sol";
import {FreezeRegistryMock, ProxyCallTarget} from "../utils/mocks/ProxyMocks.sol";

/// @title ProxyManagerUnitTest
/// @notice The ProxyManager on its own (2.5): Adapter-only CREATE2 deployment at `predictProxy(wallet, spoke,
/// marketId)`, one proxy per triple, frozen wallets refused, the check order of `deployProxy`, and a runtime code with
/// no storage, role, pause or upgrade selector.
/// @dev The Adapter is a plain address; the MarketRegistry is the freeze-only mock. The Adapter's side of TEST-025,
/// TEST-190 and TEST-271 (`proxyOf`, `UserProxyCreated`, registration in the vault token, `AaveAdapter.predictProxy`
/// and the Lens value) joins these rows with the AaveAdapter and the Lens.
contract ProxyManagerUnitTest is AvanaTest {
    using BytecodeInspector for bytes;

    uint256 internal constant MARKET_A = 3;
    uint256 internal constant MARKET_B = 4;

    address internal adapter;
    address internal spokeHub1;
    address internal spokeHub2;
    FreezeRegistryMock internal registry;
    ProxyManager internal manager;

    function setUp() public {
        adapter = makeAddr("AaveAdapter");
        spokeHub1 = makeAddr("UniswapV3StableSpoke");
        spokeHub2 = makeAddr("SecondHubSpoke");
        registry = new FreezeRegistryMock();
        manager = new ProxyManager(adapter, address(registry));
        vm.label(address(manager), "ProxyManager");
    }

    // ─── Construction ───

    // TEST-190 verifies: REQ-PROXY-050, REQ-PROXY-085, Q-226
    // Sources: 5.1 TEST-190, 2.5
    function test_TEST_190_immutablesFixedAtConstruction() public view {
        assertEq(manager.ADAPTER(), adapter, "ADAPTER");
        assertEq(manager.MARKET_REGISTRY(), address(registry), "MARKET_REGISTRY");
        assertEq(manager.PROXY_CREATION_CODE_HASH(), keccak256(type(PositionProxy).creationCode), "creation-code hash");
    }

    // TEST-190 verifies: REQ-PROXY-085
    function testFuzz_TEST_190_constructorRefusesZero(
        address a,
        address r
    ) public {
        vm.assume(a != address(0) && r != address(0));
        vm.expectRevert(IProxyManager.ZeroAddress.selector);
        new ProxyManager(address(0), r);
        vm.expectRevert(IProxyManager.ZeroAddress.selector);
        new ProxyManager(a, address(0));
        ProxyManager ok = new ProxyManager(a, r);
        assertEq(ok.ADAPTER(), a);
        assertEq(ok.MARKET_REGISTRY(), r);
    }

    // ─── Prediction ───

    /// @notice `predictProxy` is the CREATE2 address from this ProxyManager, the salt of the triple and the init code
    /// of `REQ-PROXY-052`, computed before anything is deployed.
    // TEST-190 verifies: REQ-PROXY-001, REQ-PROXY-052, REQ-PROXY-055, INV-064, ATTACK-029, Q-375
    function testFuzz_TEST_190_predictMatchesCreate2Formula(
        address wallet,
        address spoke,
        uint256 marketId
    ) public view {
        vm.assume(wallet != address(0) && spoke != address(0) && marketId != 0);
        bytes32 salt = keccak256(abi.encode(wallet, spoke, marketId));
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(PositionProxy).creationCode, abi.encode(adapter, wallet, spoke, marketId)));
        assertEq(
            manager.predictProxy(wallet, spoke, marketId),
            vm.computeCreate2Address(salt, initCodeHash, address(manager))
        );
    }

    /// @notice `predictProxy` reads nothing from the MarketRegistry: it answers while the registry reverts.
    // TEST-190 verifies: REQ-PROXY-099, REQ-PROXY-052
    function test_TEST_190_predictReadsNoRegistry() public {
        registry.setDown(true);
        address predicted = manager.predictProxy(carol, spokeHub1, MARKET_A);
        assertTrue(predicted != address(0));
    }

    // ─── Deployment ───

    // TEST-190 verifies: REQ-PROXY-051, REQ-PROXY-052, REQ-PROXY-056, REQ-PROXY-004, INV-064, INV-012, ATTACK-029, ATTACK-134
    // Sources: 5.1 TEST-190, TEST-025 (ProxyManager side), 3.1 DEP-029
    function test_TEST_190_deployAtPredictedAddress() public {
        address predicted = manager.predictProxy(carol, spokeHub1, MARKET_A);
        assertEq(predicted.code.length, 0, "no code before the first pledge");
        vm.expectEmit(true, true, true, true, address(manager));
        emit IProxyManager.ProxyDeployed(carol, spokeHub1, MARKET_A, predicted);
        vm.prank(adapter);
        address proxy = manager.deployProxy(carol, spokeHub1, MARKET_A);
        assertEq(proxy, predicted, "address");
        IPositionProxy p = IPositionProxy(proxy);
        assertEq(p.ADAPTER(), adapter, "proxy ADAPTER");
        assertEq(p.WALLET(), carol, "proxy WALLET");
        assertEq(p.SPOKE(), spokeHub1, "proxy SPOKE");
        assertEq(p.MARKET_ID(), MARKET_A, "proxy MARKET_ID");
        // The same constructor run by the ProxyManager (the creator is an immutable of the proxy).
        vm.prank(address(manager));
        PositionProxy sameCode = new PositionProxy(adapter, carol, spokeHub1, MARKET_A);
        assertEq(proxy.codehash, address(sameCode).codehash, "runtime code is the PositionProxy's");
    }

    // TEST-190 verifies: REQ-PROXY-052, REQ-PROXY-053, INV-064
    function testFuzz_TEST_190_deployEqualsPredictForAnyTriple(
        address wallet,
        address spoke,
        uint256 marketId
    ) public {
        vm.assume(wallet != address(0) && spoke != address(0) && marketId != 0);
        address predicted = manager.predictProxy(wallet, spoke, marketId);
        vm.prank(adapter);
        assertEq(manager.deployProxy(wallet, spoke, marketId), predicted);
        assertEq(IPositionProxy(predicted).WALLET(), wallet);
        assertEq(IPositionProxy(predicted).SPOKE(), spoke);
        assertEq(IPositionProxy(predicted).MARKET_ID(), marketId);
    }

    // TEST-190 verifies: REQ-PROXY-051, REQ-PROXY-097, INV-064, ATTACK-134, ATTACK-186, Q-225, REQ-ACCESS-147
    function testFuzz_TEST_190_onlyAdapterDeploys(
        address caller
    ) public {
        vm.assume(caller != adapter);
        address predicted = manager.predictProxy(carol, spokeHub1, MARKET_A);
        vm.prank(caller);
        vm.expectRevert(IProxyManager.OnlyAdapter.selector);
        manager.deployProxy(carol, spokeHub1, MARKET_A);
        assertEq(predicted.code.length, 0);
    }

    // TEST-190 verifies: REQ-PROXY-052, REQ-PROXY-097
    // Sources: PositionProxy review 2026-11-10 (I-3)
    /// @notice `predictProxy` answers only for triples `deployProxy` can deploy: a zero wallet, a zero Spoke or market
    /// 0 reverts `ZeroAddress`.
    function test_TEST_190_predictRefusesUndeployableTriples() public {
        vm.expectRevert(IProxyManager.ZeroAddress.selector);
        manager.predictProxy(address(0), spokeHub1, MARKET_A);
        vm.expectRevert(IProxyManager.ZeroAddress.selector);
        manager.predictProxy(carol, address(0), MARKET_A);
        vm.expectRevert(IProxyManager.ZeroAddress.selector);
        manager.predictProxy(carol, spokeHub1, 0);
    }

    // TEST-190 verifies: REQ-PROXY-051, REQ-PROXY-097
    function test_TEST_190_zeroArgumentsRefused() public {
        vm.startPrank(adapter);
        vm.expectRevert(IProxyManager.ZeroAddress.selector);
        manager.deployProxy(address(0), spokeHub1, MARKET_A);
        vm.expectRevert(IProxyManager.ZeroAddress.selector);
        manager.deployProxy(carol, address(0), MARKET_A);
        vm.expectRevert(IProxyManager.ZeroAddress.selector);
        manager.deployProxy(carol, spokeHub1, 0);
        vm.stopPrank();
    }

    // TEST-190 verifies: REQ-PROXY-051, REQ-PROXY-053, REQ-PROXY-097, REQ-PROXY-100, INV-064, ATTACK-156
    function test_TEST_190_secondDeployReverts() public {
        vm.startPrank(adapter);
        address first = manager.deployProxy(carol, spokeHub1, MARKET_A);
        vm.expectRevert(abi.encodeWithSelector(IProxyManager.ProxyExists.selector, carol, spokeHub1, MARKET_A));
        manager.deployProxy(carol, spokeHub1, MARKET_A);
        vm.stopPrank();
        assertEq(manager.predictProxy(carol, spokeHub1, MARKET_A), first, "prediction unchanged after deployment");
    }

    /// @notice ETH sent to a predicted address before the first pledge does not block the deployment.
    // TEST-190 verifies: REQ-PROXY-051, REQ-PROXY-052, ATTACK-134
    function test_TEST_190_prefundedAddressStillDeploys() public {
        address predicted = manager.predictProxy(carol, spokeHub1, MARKET_A);
        vm.deal(predicted, 1 ether);
        vm.prank(adapter);
        assertEq(manager.deployProxy(carol, spokeHub1, MARKET_A), predicted);
    }

    /// @notice The same code with the same arguments deployed by anyone else lands at another address: the deployer is
    /// part of the CREATE2 address.
    // TEST-190 verifies: REQ-PROXY-003, REQ-PROXY-055, ATTACK-029, ATTACK-134
    function test_TEST_190_otherDeployerCannotOccupyAddress() public {
        address predicted = manager.predictProxy(carol, spokeHub1, MARKET_A);
        bytes32 salt = keccak256(abi.encode(carol, spokeHub1, MARKET_A));
        vm.prank(attacker);
        PositionProxy squat = new PositionProxy{salt: salt}(adapter, carol, spokeHub1, MARKET_A);
        assertTrue(address(squat) != predicted, "squatted the predicted address");
        assertEq(predicted.code.length, 0);
        vm.prank(adapter);
        assertEq(manager.deployProxy(carol, spokeHub1, MARKET_A), predicted);
    }

    // ─── Freeze ───

    // TEST-229 verifies: REQ-PROXY-099, REQ-PROXY-102, Q-242, REQ-ACCESS-147, REQ-MREG-023
    // Sources: 5.1 TEST-229 (ProxyManager side)
    function test_TEST_229_frozenWalletGetsNoProxy() public {
        registry.setFrozen(carol, true);
        address predicted = manager.predictProxy(carol, spokeHub1, MARKET_A);
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(IProxyManager.AddressIsFrozen.selector, carol));
        manager.deployProxy(carol, spokeHub1, MARKET_A);
        assertEq(predicted.code.length, 0);
        registry.setFrozen(carol, false);
        vm.prank(adapter);
        assertEq(manager.deployProxy(carol, spokeHub1, MARKET_A), predicted, "unfrozen wallet gets its proxy");
    }

    /// @notice The freeze is read for the wallet only, and only on deployment.
    // TEST-229 verifies: REQ-PROXY-099, REQ-MREG-023
    function test_TEST_229_freezeReadForWalletOnly() public {
        registry.setFrozen(spokeHub1, true);
        registry.setFrozen(adapter, true);
        vm.expectCall(address(registry), abi.encodeCall(FreezeRegistryMock.isFrozenAddress, (carol)), 1);
        vm.prank(adapter);
        manager.deployProxy(carol, spokeHub1, MARKET_A);
    }

    /// @notice A registry that reverts stops new proxies only; its error propagates.
    // TEST-229 verifies: REQ-PROXY-099, REQ-CONFIG-069
    function test_TEST_229_registryRevertPropagates() public {
        registry.setDown(true);
        vm.prank(adapter);
        vm.expectRevert(FreezeRegistryMock.RegistryDown.selector);
        manager.deployProxy(carol, spokeHub1, MARKET_A);
    }

    // ─── Check order ───

    /// @notice OnlyAdapter, then ZeroAddress, then ProxyExists, then AddressIsFrozen.
    // TEST-190 verifies: REQ-PROXY-051, REQ-PROXY-097, REQ-PROXY-099
    function test_TEST_190_checkOrder() public {
        registry.setFrozen(carol, true);
        vm.prank(carol);
        vm.expectRevert(IProxyManager.OnlyAdapter.selector);
        manager.deployProxy(carol, address(0), 0);

        vm.prank(adapter);
        vm.expectRevert(IProxyManager.ZeroAddress.selector);
        manager.deployProxy(carol, address(0), MARKET_A);

        registry.setFrozen(carol, false);
        vm.prank(adapter);
        manager.deployProxy(carol, spokeHub1, MARKET_A);
        registry.setFrozen(carol, true);
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(IProxyManager.ProxyExists.selector, carol, spokeHub1, MARKET_A));
        manager.deployProxy(carol, spokeHub1, MARKET_A);
    }

    // ─── Isolation: one proxy per (wallet, Spoke, market) ───

    /// @notice One wallet in two markets of one Spoke and one market of a second Hub's Spoke gets three proxies, each
    /// bound to its own triple and driven only by the chain's Adapter (the ProxyManager included is refused).
    // TEST-271 verifies: REQ-PROXY-053, REQ-PROXY-055, REQ-PROXY-100, INV-063, INV-064, ATTACK-162, ATTACK-186, Q-276, Q-307
    // Sources: 5.1 TEST-271, TEST-190, TEST-025 (second market)
    function test_TEST_271_onePerWalletSpokeMarket() public {
        vm.startPrank(adapter);
        address pA = manager.deployProxy(carol, spokeHub1, MARKET_A);
        address pB = manager.deployProxy(carol, spokeHub1, MARKET_B);
        address pC = manager.deployProxy(carol, spokeHub2, MARKET_A);
        vm.stopPrank();
        assertTrue(pA != pB && pA != pC && pB != pC, "proxies distinct");
        assertEq(IPositionProxy(pB).MARKET_ID(), MARKET_B);
        assertEq(IPositionProxy(pC).SPOKE(), spokeHub2);

        ProxyCallTarget target = new ProxyCallTarget();
        bytes memory data = abi.encodeCall(ProxyCallTarget.ping, (1));
        address[3] memory proxies = [pA, pB, pC];
        for (uint256 i = 0; i < proxies.length; ++i) {
            vm.prank(address(manager));
            vm.expectRevert(IPositionProxy.OnlyAdapter.selector);
            IPositionProxy(proxies[i]).execute(address(target), data);
            vm.prank(carol);
            vm.expectRevert(IPositionProxy.OnlyAdapter.selector);
            IPositionProxy(proxies[i]).execute(address(target), data);
            vm.prank(adapter);
            IPositionProxy(proxies[i]).execute(address(target), data);
            assertEq(target.lastCaller(), proxies[i], "Adapter drives each proxy");
        }
    }

    // TEST-271 verifies: REQ-PROXY-052, REQ-PROXY-053, INV-064, ATTACK-162
    function testFuzz_TEST_271_distinctTriplesDistinctAddresses(
        address w1,
        address s1,
        uint256 m1,
        address w2,
        address s2,
        uint256 m2
    ) public view {
        vm.assume(w1 != address(0) && s1 != address(0) && m1 != 0 && w2 != address(0) && s2 != address(0) && m2 != 0);
        vm.assume(w1 != w2 || s1 != s2 || m1 != m2);
        assertTrue(manager.predictProxy(w1, s1, m1) != manager.predictProxy(w2, s2, m2));
    }

    // ─── Code surface ───

    /// @notice Own selectors (the embedded PositionProxy creation code excluded) are exactly `deployProxy`,
    /// `predictProxy` and the three views; no role, owner, pause, upgrade or proxy-code-changing selector exists, and
    /// the code has no storage access, `delegatecall`, `selfdestruct` or `tx.origin`.
    // TEST-191 verifies: REQ-PROXY-050, REQ-PROXY-054, REQ-PROXY-086, REQ-PROXY-101, REQ-PROXY-103, INV-065, ATTACK-123, ATTACK-156, REQ-ACCESS-147, REQ-ACCESS-176, REQ-ACCESS-015, REQ-ACCESS-066, REQ-ACCESS-113
    // Sources: 5.1 TEST-191, TEST-168, TEST-242, TEST-032 (ProxyManager inventory)
    function test_TEST_191_selectorInventoryAndOpcodes() public view {
        bytes memory code = address(manager).code;
        bytes memory blob = type(PositionProxy).creationCode;
        uint256 at = code.indexOf(blob);
        assertTrue(at != type(uint256).max, "creation code embedded");
        bytes4[] memory head = code.dispatcherSelectors(0, at);
        bytes4[] memory tail = code.dispatcherSelectors(at + blob.length, code.length);
        bytes4[5] memory expected = [
            IProxyManager.deployProxy.selector,
            IProxyManager.predictProxy.selector,
            IProxyManager.PROXY_CREATION_CODE_HASH.selector,
            IProxyManager.ADAPTER.selector,
            IProxyManager.MARKET_REGISTRY.selector
        ];
        assertEq(head.length + tail.length, expected.length, "selector count");
        for (uint256 i = 0; i < expected.length; ++i) {
            assertTrue(_has(head, expected[i]) || _has(tail, expected[i]), "expected selector missing");
        }
        bytes4[8] memory forbidden = [
            bytes4(keccak256("grantRole(bytes32,address)")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("upgradeToAndCall(address,bytes)")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("setImplementation(address)")),
            bytes4(keccak256("isProxy(address)")),
            bytes4(keccak256("multicall(bytes[])")),
            bytes4(keccak256("execute(address,bytes)"))
        ];
        for (uint256 i = 0; i < forbidden.length; ++i) {
            assertFalse(code.pushesSelector(0, at, forbidden[i]), "forbidden selector present");
            assertFalse(code.pushesSelector(at + blob.length, code.length, forbidden[i]), "forbidden selector present");
        }
        uint8[8] memory ops = [0xf4, 0xf2, 0xff, 0x32, 0x54, 0x55, 0x5c, 0x5d];
        for (uint256 i = 0; i < ops.length; ++i) {
            assertFalse(code.hasOpcode(0, at, ops[i]), "forbidden opcode present");
        }
        assertTrue(code.hasOpcode(0, at, 0xf5), "CREATE2 present (sanity of the scan)");
    }

    /// @notice The PositionProxy has no initialize step: neither its creation code (the blob the ProxyManager embeds)
    /// nor a deployed proxy's runtime code carries an `initialize`, `reinitializer` or `init` selector, the binding
    /// is set by the constructor, and the creation code's hash is fixed in the ProxyManager.
    // TEST-252 verifies: REQ-PROXY-004, REQ-PROXY-085, REQ-PROXY-050
    // Sources: 5.1 TEST-252 (ProxyManager and PositionProxy part), Q-264
    function test_TEST_252_noInitializerAndFixedCreationCodeHash() public {
        bytes memory blob = type(PositionProxy).creationCode;
        assertEq(manager.PROXY_CREATION_CODE_HASH(), keccak256(blob), "creation-code hash fixed");
        assertTrue(address(manager).code.indexOf(blob) != type(uint256).max, "the embedded blob is that code");
        vm.prank(adapter);
        address proxy = manager.deployProxy(carol, spokeHub1, MARKET_A);
        bytes memory runtime = proxy.code;
        bytes4[6] memory inits = [
            bytes4(keccak256("initialize()")),
            bytes4(keccak256("initialize(address)")),
            bytes4(keccak256("initialize(address,address,address,uint256)")),
            bytes4(keccak256("init(address,address,uint256)")),
            bytes4(keccak256("reinitialize(uint64)")),
            bytes4(keccak256("upgradeToAndCall(address,bytes)"))
        ];
        for (uint256 i = 0; i < inits.length; ++i) {
            assertFalse(blob.pushesSelector(0, blob.length, inits[i]), "initializer selector in the creation code");
            assertFalse(runtime.pushesSelector(0, runtime.length, inits[i]), "initializer selector in the runtime code");
        }
        assertEq(IPositionProxy(proxy).WALLET(), carol, "binding set by the constructor");
        assertEq(IPositionProxy(proxy).SPOKE(), spokeHub1, "spoke");
        assertEq(IPositionProxy(proxy).MARKET_ID(), MARKET_A, "market");
        assertEq(IPositionProxy(proxy).ADAPTER(), adapter, "adapter");
    }

    /// @notice No ETH entry point: plain ETH and an unknown selector revert.
    // TEST-191 verifies: REQ-PROXY-050, REQ-PROXY-103
    function test_TEST_191_noEthAndNoFallback() public {
        vm.deal(address(this), 1 ether);
        (bool sent,) = address(manager).call{value: 1}("");
        assertFalse(sent, "plain ETH accepted");
        (bool unknown,) = address(manager).call(abi.encodeWithSignature("upgradeTo(address)", address(1)));
        assertFalse(unknown, "unknown selector accepted");
    }

    /// @notice Deployment writes no storage of the ProxyManager (no registry of proxies).
    // TEST-089 verifies: REQ-PROXY-054
    function test_TEST_089_deploymentWritesNoManagerStorage() public {
        vm.record();
        vm.prank(adapter);
        manager.deployProxy(carol, spokeHub1, MARKET_A);
        (, bytes32[] memory writes) = vm.accesses(address(manager));
        assertEq(writes.length, 0, "ProxyManager wrote storage");
    }

    function _has(
        bytes4[] memory list,
        bytes4 s
    ) private pure returns (bool) {
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == s) return true;
        }
        return false;
    }
}
