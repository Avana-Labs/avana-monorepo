// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {MarketParams} from "../../src/policy/parameter-store/types/MarketParams.sol";
import {SecondSource} from "../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../src/types/SecondSourceKind.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockAggregator} from "../utils/mocks/ParameterStoreMocks.sol";

/// @notice REQ-PSTORE-034 on an L2: the sequencer grace period covers every TWAP window the store governs, the
/// market's own window and the window of each token's recorded and standby pool-TWAP second source, checked on every
/// side that can change: `setSequencer`, `setTwapWindow`, `setInitialMarketParams` and `setSecondSource`; each edge is
/// exact (`window == gracePeriod` passes, one second more is refused `OutOfBounds`).
contract ParameterStoreSequencerGraceUnitTest is ParameterStoreFixture {
    MockAggregator internal seq;
    bytes internal oob = abi.encodeWithSelector(IParameterStoreErrors.OutOfBounds.selector);

    function setUp() public {
        _deployStore(true);
        seq = new MockAggregator(0, 0, 0);
        seq.setRound(0, 1_000_000);
        vm.prank(address(timelock));
        store.setSequencer(address(seq), 3600);
        _listMarket();
    }

    function _twap(
        uint32 window
    ) internal view returns (SecondSource memory) {
        return SecondSource(SecondSourceKind.PoolTwap, address(integration), bytes32(uint256(0xC0FFEE)), 0, window, 120);
    }

    function _call(
        bytes memory data
    ) internal returns (bool ok, bytes memory ret) {
        vm.prank(address(timelock));
        (ok, ret) = address(store).call(data);
    }

    function _grace() internal view returns (uint32 grace) {
        (, grace) = store.sequencer();
    }

    // TEST-250 verifies: REQ-PSTORE-034, REQ-PSTORE-023
    function test_TEST_250_graceNeverBelowTheMarketWindow() public {
        // Market window 1,800 s: a grace of 1,800 s passes, 1,799 s is refused.
        (bool ok, bytes memory ret) = _call(abi.encodeCall(store.setSequencer, (address(seq), 1799)));
        assertFalse(ok, "grace below the market window accepted");
        assertEq(ret, oob);
        assertEq(_grace(), 3600);
        (ok,) = _call(abi.encodeCall(store.setSequencer, (address(seq), 1800)));
        assertTrue(ok);
        assertEq(_grace(), 1800);
    }

    // TEST-250 verifies: REQ-PSTORE-034, REQ-PSTORE-027
    function test_TEST_250_marketWindowNeverAboveTheGrace() public {
        (bool ok, bytes memory ret) = _call(abi.encodeCall(store.setTwapWindow, (M, 3601)));
        assertFalse(ok, "window above the grace accepted");
        assertEq(ret, oob);
        (ok,) = _call(abi.encodeCall(store.setTwapWindow, (M, 3600)));
        assertTrue(ok);
        assertEq(store.getMarketParams(M).twapWindow, 3600);
    }

    // TEST-250 verifies: REQ-PSTORE-034, REQ-PSTORE-004
    function test_TEST_250_listingWindowNeverAboveTheGrace() public {
        MarketParams memory p = _launchMarketParams();
        p.twapWindow = 3601;
        (bool ok, bytes memory ret) = _call(abi.encodeCall(store.setInitialMarketParams, (M, p)));
        assertFalse(ok, "listing window above the grace accepted");
        assertEq(ret, oob);
        p.twapWindow = 3600;
        (ok,) = _call(abi.encodeCall(store.setInitialMarketParams, (M, p)));
        assertTrue(ok);
    }

    // TEST-250 verifies: REQ-PSTORE-034, REQ-PSTORE-028, REQ-PSTORE-029
    function test_TEST_250_secondSourceWindowNeverAboveTheGrace() public {
        // As the recorded source and as the standby, for a token in a market and for a token in none (GHO).
        address[2] memory tokens = [usdc, gho];
        for (uint256 i = 0; i < tokens.length; ++i) {
            (bool ok, bytes memory ret) =
                _call(abi.encodeCall(store.setSecondSource, (tokens[i], _twap(3601), _twap0())));
            assertFalse(ok, "recorded window above the grace accepted");
            assertEq(ret, oob);
            (ok, ret) = _call(abi.encodeCall(store.setSecondSource, (tokens[i], _twap(1800), _standby(3601))));
            assertFalse(ok, "standby window above the grace accepted");
            assertEq(ret, oob);
            (ok,) = _call(abi.encodeCall(store.setSecondSource, (tokens[i], _twap(3600), _standby(3600))));
            assertTrue(ok, "windows at the grace refused");
        }
    }

    // TEST-250 verifies: REQ-PSTORE-034, REQ-PSTORE-023
    function test_TEST_250_graceNeverBelowASecondSourceWindow() public {
        // Market window 1,200 s; USDC's recorded source 1,500 s, its standby 2,400 s: the grace stays >= 2,400 s.
        SecondSource memory standby = _standby(2400);
        (bool ok,) = _call(abi.encodeCall(store.setTwapWindow, (M, 1200)));
        assertTrue(ok);
        (ok,) = _call(abi.encodeCall(store.setSecondSource, (usdc, _twap(1500), standby)));
        assertTrue(ok);
        bytes memory ret;
        (ok, ret) = _call(abi.encodeCall(store.setSequencer, (address(seq), 2399)));
        assertFalse(ok, "grace below the standby window accepted");
        assertEq(ret, oob);
        (ok,) = _call(abi.encodeCall(store.setSequencer, (address(seq), 2400)));
        assertTrue(ok);
        // With an empty standby the recorded source's window binds.
        (ok,) = _call(abi.encodeCall(store.setSecondSource, (usdc, _twap(1500), _twap0())));
        assertTrue(ok);
        (ok, ret) = _call(abi.encodeCall(store.setSequencer, (address(seq), 1499)));
        assertFalse(ok, "grace below the recorded window accepted");
        assertEq(ret, oob);
        (ok,) = _call(abi.encodeCall(store.setSequencer, (address(seq), 1500)));
        assertTrue(ok);
        assertEq(_grace(), 1500);
    }

    // TEST-250 verifies: REQ-PSTORE-034
    function test_TEST_250_noWindowBeforeTheSequencerIsSet() public {
        // A fresh L2 store with no sequencer yet (grace 0) refuses every positive window until setSequencer runs.
        _deployStore(true);
        (bool ok, bytes memory ret) = _call(abi.encodeCall(store.setTwapWindow, (M, 1)));
        assertFalse(ok);
        assertEq(ret, oob);
    }

    function _twap0() internal pure returns (SecondSource memory s) {}

    /// @dev A pool-TWAP standby through another reader and another pool.
    function _standby(
        uint32 window
    ) internal view returns (SecondSource memory) {
        return SecondSource(SecondSourceKind.PoolTwap, address(pool), bytes32(uint256(0xBEEF)), 0, window, 120);
    }
}

/// @notice REQ-PSTORE-034 on Ethereum: with no sequencer, no window is bounded by a grace period (0).
contract ParameterStoreSequencerGraceL1UnitTest is ParameterStoreFixture {
    function setUp() public {
        _deployStore(false);
        _listMarket();
    }

    // TEST-250 verifies: REQ-PSTORE-034, REQ-PSTORE-023
    function test_TEST_250_noSequencerNoGraceBound() public {
        vm.prank(address(timelock));
        store.setTwapWindow(M, 7200);
        assertEq(store.getMarketParams(M).twapWindow, 7200);
        vm.prank(address(timelock));
        store.setSecondSource(
            usdc,
            SecondSource(SecondSourceKind.PoolTwap, address(integration), bytes32(uint256(0xC0FFEE)), 0, 7200, 120),
            SecondSource(SecondSourceKind.None, address(0), bytes32(0), 0, 0, 0)
        );
        assertEq(store.secondSource(usdc).twapWindow, 7200);
    }
}
