// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IPositionProxy} from "../../src/proxy/position-proxy/IPositionProxy.sol";
import {PositionProxy} from "../../src/proxy/position-proxy/PositionProxy.sol";
import {ProxyManager} from "../../src/proxy/proxy-manager/ProxyManager.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {StubRegistryMock} from "../utils/mocks/ProxyMocks.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";
import {ProxyManagerHandler} from "./handlers/ProxyManagerHandler.sol";

/// @title ProxyManagerInvariantTest
/// @notice ProxyManager and PositionProxy half of TEST-089: random deployments by the Adapter, deployment and
/// execution attempts by strangers, and Adapter calls through the proxies. After every call: code sits at
/// `predictProxy` exactly for the triples the Adapter deployed, each such proxy has the PositionProxy code and its own
/// unchanged binding, and no second, stranger or misplaced deployment and no stranger execution ever succeeded.
/// @dev The vault-token registry and the Adapter's `proxyOf` records of TEST-089 join this row with the AaveAdapter.
contract ProxyManagerInvariantTest is AvanaTest, HandlerReach {
    ProxyManagerHandler internal handler;
    ProxyManager internal manager;
    address internal adapter;

    function setUp() public {
        adapter = makeAddr("AaveAdapter");
        StubRegistryMock registry = new StubRegistryMock();
        manager = new ProxyManager(adapter, address(registry));
        handler = new ProxyManagerHandler(manager, adapter);
        targetContract(address(handler));
        bytes4[] memory actions = new bytes4[](4);
        actions[0] = ProxyManagerHandler.deploy.selector;
        actions[1] = ProxyManagerHandler.strangerDeploy.selector;
        actions[2] = ProxyManagerHandler.strangerExecute.selector;
        actions[3] = ProxyManagerHandler.adapterExecute.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
    }

    // TEST-082 verifies: TEST-007
    /// @notice What the handler does: over 32 fixed-seed runs of 50 calls from set-up, counts per action the calls that
    /// changed the state of a contract other than the handler and this test, the skipped and failed calls and the
    /// calls that returned without changing anything; each action must change the state in at least its floor of
    /// calls (`forge test -vv` prints the table).
    function test_TEST_082_handlerReach() public {
        (bytes4[] memory actions, string[] memory names,) = _reachActions();
        address[] memory own = new address[](2);
        (own[0], own[1]) = (address(handler), address(this));
        Reach memory r =
            _replayLanded(address(handler), actions, ProxyManagerHandler.Skipped.selector, 32, 50, 0, own, true);
        // Floors: 80 % of the landed share measured with these seeds, rounded down to 5 %; a check's normal return lands.
        uint256[] memory floors = new uint256[](4);
        bool[] memory check = new bool[](4);
        floors[0] = 40; // deploy
        floors[1] = 80; // strangerDeploy
        check[1] = true; // strangerDeploy
        floors[2] = 20; // strangerExecute
        check[2] = true; // strangerExecute
        floors[3] = 15; // adapterExecute
        _check(r, names, new string[](0), floors, new uint256[](0), check);
    }

    function _reached() internal pure override returns (bool[] memory hit) {
        hit = new bool[](0);
    }

    /// @dev The targeted actions, their names and the type of each of their parameters (see `_typed`).
    function _reachActions()
        internal
        pure
        returns (bytes4[] memory actions, string[] memory names, int16[][] memory kinds)
    {
        (actions, names, kinds) = (new bytes4[](4), new string[](4), new int16[][](4));
        (actions[0], names[0]) = (ProxyManagerHandler.deploy.selector, "deploy");
        kinds[0] = new int16[](1);
        kinds[0][0] = 256;
        (actions[1], names[1]) = (ProxyManagerHandler.strangerDeploy.selector, "strangerDeploy");
        kinds[1] = new int16[](2);
        kinds[1][0] = 160;
        kinds[1][1] = 256;
        (actions[2], names[2]) = (ProxyManagerHandler.strangerExecute.selector, "strangerExecute");
        kinds[2] = new int16[](2);
        kinds[2][0] = 160;
        kinds[2][1] = 256;
        (actions[3], names[3]) = (ProxyManagerHandler.adapterExecute.selector, "adapterExecute");
        kinds[3] = new int16[](2);
        kinds[3][0] = 256;
        kinds[3][1] = 128;
    }

    function _calldata(
        bytes4 selector,
        uint256 seed
    ) internal pure override returns (bytes memory) {
        (bytes4[] memory actions,, int16[][] memory kinds) = _reachActions();
        for (uint256 k = 0; k < actions.length; ++k) {
            if (actions[k] == selector) return _typed(selector, kinds[k], seed);
        }
        return abi.encodePacked(selector);
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
