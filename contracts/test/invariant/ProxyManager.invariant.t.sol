// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IPositionProxy} from "../../src/proxy/position-proxy/IPositionProxy.sol";
import {PositionProxy} from "../../src/proxy/position-proxy/PositionProxy.sol";
import {ProxyManager} from "../../src/proxy/proxy-manager/ProxyManager.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {FreezeRegistryMock} from "../utils/mocks/ProxyMocks.sol";
import {ProxyManagerHandler} from "./handlers/ProxyManagerHandler.sol";

/// @title ProxyManagerInvariantTest
/// @notice ProxyManager and PositionProxy half of TEST-089: random deployments by the Adapter (frozen wallets
/// included), deployment and execution attempts by strangers, and Adapter calls through the proxies. After every call:
/// code sits at `predictProxy` exactly for the triples the Adapter deployed, each such proxy has the PositionProxy code
/// and its own unchanged binding, and no second, frozen, stranger or misplaced deployment and no stranger execution
/// ever succeeded.
/// @dev The vault-token registry and the Adapter's `proxyOf` records of TEST-089 join this row with the AaveAdapter.
contract ProxyManagerInvariantTest is AvanaTest {
    ProxyManagerHandler internal handler;
    ProxyManager internal manager;
    address internal adapter;

    function setUp() public {
        adapter = makeAddr("AaveAdapter");
        FreezeRegistryMock registry = new FreezeRegistryMock();
        manager = new ProxyManager(adapter, address(registry));
        handler = new ProxyManagerHandler(manager, registry, adapter);
        targetContract(address(handler));
        bytes4[] memory actions = new bytes4[](5);
        actions[0] = ProxyManagerHandler.deploy.selector;
        actions[1] = ProxyManagerHandler.strangerDeploy.selector;
        actions[2] = ProxyManagerHandler.strangerExecute.selector;
        actions[3] = ProxyManagerHandler.adapterExecute.selector;
        actions[4] = ProxyManagerHandler.setFrozen.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
    }

    // TEST-089 verifies: REQ-PROXY-051, REQ-PROXY-052, REQ-PROXY-053, REQ-PROXY-099, REQ-PROXY-100, INV-012, INV-064
    // Sources: 5.1 TEST-089 (ProxyManager and PositionProxy side), QNT-08
    function invariant_TEST_089_proxiesOnlyAtDeployedPredictions() public view {
        bytes32 runtimeHash;
        for (uint256 i = 0; i < handler.TRIPLES(); ++i) {
            (address w, address s, uint256 m) = handler.triple(i);
            address p = manager.predictProxy(w, s, m);
            assertEq(p.code.length != 0, handler.deployed(i), "code iff deployed");
            if (!handler.deployed(i)) continue;
            IPositionProxy proxy = IPositionProxy(p);
            assertEq(proxy.ADAPTER(), adapter, "ADAPTER");
            assertEq(proxy.WALLET(), w, "WALLET");
            assertEq(proxy.SPOKE(), s, "SPOKE");
            assertEq(proxy.MARKET_ID(), m, "MARKET_ID");
            if (runtimeHash == bytes32(0)) runtimeHash = keccak256(_runtimeWithoutImmutables(p));
            assertEq(keccak256(_runtimeWithoutImmutables(p)), runtimeHash, "every proxy runs the same code");
        }
    }

    // TEST-089 verifies: REQ-PROXY-051, REQ-PROXY-053, REQ-PROXY-099, REQ-PROXY-102, INV-063, INV-064
    function invariant_TEST_089_noForbiddenSuccess() public view {
        assertEq(handler.secondDeploySucceeded(), 0, "second deployment of a triple");
        assertEq(handler.frozenDeploySucceeded(), 0, "deployment for a frozen wallet");
        assertEq(handler.strangerDeploySucceeded(), 0, "deployment by a stranger");
        assertEq(handler.deployedAtWrongAddress(), 0, "deployment away from predictProxy");
        assertEq(handler.strangerExecuteSucceeded(), 0, "execution by a stranger");
        assertEq(handler.adapterExecuteFailed(), 0, "Adapter call through a proxy failed");
    }

    // TEST-089 verifies: REQ-PROXY-050, REQ-PROXY-085, INV-065
    function invariant_TEST_089_managerImmutablesFixed() public view {
        assertEq(manager.ADAPTER(), adapter);
        assertEq(manager.PROXY_CREATION_CODE_HASH(), keccak256(type(PositionProxy).creationCode));
    }

    /// @dev Runtime code with the immutable words zeroed: the four bindings differ per proxy, the rest is shared.
    function _runtimeWithoutImmutables(
        address p
    ) internal view returns (bytes memory code) {
        code = p.code;
        IPositionProxy proxy = IPositionProxy(p);
        bytes32[4] memory words = [
            bytes32(uint256(uint160(proxy.ADAPTER()))),
            bytes32(uint256(uint160(proxy.WALLET()))),
            bytes32(uint256(uint160(proxy.SPOKE()))),
            bytes32(proxy.MARKET_ID())
        ];
        for (uint256 i = 0; i + 33 <= code.length; ++i) {
            if (uint8(code[i]) != 0x7f) continue;
            bytes32 word;
            assembly ("memory-safe") {
                word := mload(add(add(code, 33), i))
            }
            for (uint256 k = 0; k < 4; ++k) {
                if (word == words[k]) {
                    assembly ("memory-safe") {
                        mstore(add(add(code, 33), i), 0)
                    }
                }
            }
        }
    }
}
