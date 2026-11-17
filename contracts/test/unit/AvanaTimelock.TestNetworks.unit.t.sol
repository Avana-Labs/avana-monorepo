// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaTimelock} from "../../src/governance/timelock/AvanaTimelock.sol";
import {IAvanaTimelockErrors} from "../../src/governance/timelock/IAvanaTimelockErrors.sol";
import {SelectorPair} from "../../src/governance/timelock/types/SelectorPair.sol";
import {IParameterStoreTighten} from "../../src/policy/parameter-store/IParameterStoreTighten.sol";
import {TimelockFixture} from "../utils/fixtures/TimelockFixture.sol";
import {TimelockShortDelayLists} from "../utils/fixtures/TimelockShortDelayLists.sol";
import {CallRecorder} from "../utils/mocks/CallRecorder.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title AvanaTimelockTestNetworksUnitTest
/// @notice The delay floors by chain (2.15 `REQ-ACCESS-187`): 60 s for `SHORT_DELAY` and `MIN_NORMAL_DELAY` on
/// Sepolia, Base Sepolia and the local development nodes, the production values on every other chain, both fixed at
/// construction.
contract AvanaTimelockTestNetworksUnitTest is TimelockFixture {
    bytes32 internal constant SALT = keccak256("test-networks");
    uint256 internal constant TEST_DELAY = 60;

    function setUp() public {
        vm.warp(1_780_000_000);
        parameterStore = new CallRecorder();
        marketRegistry = new CallRecorder();
        lpVaultSwap = new CallRecorder();
        other = new CallRecorder();
    }

    function _on(
        uint256 chainId,
        uint256 normalDelay
    ) internal returns (AvanaTimelock) {
        SelectorPair[] memory shortList = TimelockShortDelayLists.shortEligible(
            address(parameterStore), address(marketRegistry), address(lpVaultSwap)
        );
        SelectorPair[] memory dao = TimelockShortDelayLists.daoOnlyCancel(address(marketRegistry), address(lpVaultSwap));
        return _newTimelockOn(chainId, normalDelay, true, shortList, dao, _targetsOf(shortList, dao));
    }

    function _testChain(
        uint256 i
    ) internal pure returns (uint256) {
        uint256[4] memory ids = [uint256(11_155_111), 84_532, 31_337, 31_338];
        return ids[i % 4];
    }

    function _tighten() internal view returns (Call memory) {
        return
            Call(address(parameterStore), abi.encodeCall(IParameterStoreTighten.tightenMarketUsdCap, (1, 4_000_000e8)));
    }

    // TEST-345 verifies: REQ-ACCESS-187
    /// @notice On each test network the floors are 60 s: the constructor takes a 120 s normal delay, a normal
    /// operation runs at 120 s and a short one at 60 s, and below 60 s every schedule and `setNormalDelay` reverts.
    function test_TEST_345_testNetworksTakeShortFloors() public {
        for (uint256 i = 0; i < 4; ++i) {
            timelock = _on(_testChain(i), 120);
            assertEq(timelock.SHORT_DELAY(), TEST_DELAY, "SHORT_DELAY");
            assertEq(timelock.MIN_NORMAL_DELAY(), TEST_DELAY, "MIN_NORMAL_DELAY");
            assertEq(timelock.getMinDelay(), TEST_DELAY, "getMinDelay");
            assertEq(timelock.normalDelay(), 120, "normalDelay");
            assertEq(timelock.MAX_DELAY(), 432_000, "MAX_DELAY");
            assertEq(timelock.GRACE_PERIOD(), 1_209_600, "GRACE_PERIOD");

            Call[] memory normal = _one(address(other), hex"11111111");
            assertEq(_required(normal), 120);
            bytes32 id = _schedule(governanceMultisig, normal, 120, SALT);
            vm.warp(vm.getBlockTimestamp() + 119);
            assertFalse(timelock.isOperationReady(id));
            vm.warp(vm.getBlockTimestamp() + 1);
            _execute(governanceMultisig, normal, SALT);
            assertTrue(timelock.isOperationDone(id));

            Call[] memory short = _one(_tighten().target, _tighten().data);
            assertEq(_required(short), TEST_DELAY);
            (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(short);
            vm.prank(governanceMultisig);
            vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, 59, 60));
            timelock.scheduleBatch(t, v, p, bytes32(0), SALT, 59);
            _schedule(governanceMultisig, short, TEST_DELAY, SALT);
            vm.warp(vm.getBlockTimestamp() + TEST_DELAY);
            _execute(governanceMultisig, short, SALT);

            vm.prank(address(timelock));
            vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.DelayOutOfBounds.selector, 59));
            timelock.setNormalDelay(59);
            vm.prank(address(timelock));
            timelock.setNormalDelay(TEST_DELAY);
            assertEq(timelock.normalDelay(), TEST_DELAY);
        }
    }

    // TEST-345 verifies: REQ-ACCESS-187
    /// @notice Below 60 s the constructor refuses the normal delay on a test network.
    function test_TEST_345_testNetworksRefuseNormalDelayBelowFloor() public {
        for (uint256 i = 0; i < 4; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.DelayOutOfBounds.selector, 59));
            this.deployOn(_testChain(i), 59);
        }
    }

    // TEST-345 verifies: REQ-ACCESS-187
    /// @notice Every other chain (any ID up to 2^64 outside the four) keeps 43,200 s and 345,600 s: a 120 s or
    /// 345,599 s normal delay is refused, 345,600 s is taken, and a short operation below 43,200 s is refused.
    function testFuzz_TEST_345_otherChainsKeepProductionFloors(
        uint64 chainId
    ) public {
        vm.assume(chainId != 11_155_111 && chainId != 84_532 && chainId != 31_337 && chainId != 31_338);
        vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.DelayOutOfBounds.selector, 120));
        this.deployOn(chainId, 120);
        vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.DelayOutOfBounds.selector, 345_599));
        this.deployOn(chainId, 345_599);
        timelock = _on(chainId, 345_600);
        assertEq(timelock.SHORT_DELAY(), 43_200);
        assertEq(timelock.MIN_NORMAL_DELAY(), 345_600);
        assertEq(timelock.getMinDelay(), 43_200);
        Call[] memory short = _one(_tighten().target, _tighten().data);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(short);
        vm.prank(governanceMultisig);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, 43_199, 43_200));
        timelock.scheduleBatch(t, v, p, bytes32(0), SALT, 43_199);
    }

    // TEST-345 verifies: REQ-ACCESS-187
    /// @notice The floors are fixed at construction: a timelock built on Sepolia keeps 60 s on any chain ID later, and
    /// one built on Ethereum keeps 43,200 s and 345,600 s on Sepolia.
    function test_TEST_345_floorsFixedAtConstruction() public {
        AvanaTimelock sepolia = _on(11_155_111, 120);
        AvanaTimelock ethereum = _on(1, 432_000);
        vm.chainId(1);
        assertEq(sepolia.SHORT_DELAY(), TEST_DELAY);
        assertEq(sepolia.MIN_NORMAL_DELAY(), TEST_DELAY);
        vm.chainId(11_155_111);
        assertEq(ethereum.SHORT_DELAY(), 43_200);
        assertEq(ethereum.MIN_NORMAL_DELAY(), 345_600);
    }

    /// @dev External, so `vm.expectRevert` sees the constructor's revert.
    function deployOn(
        uint256 chainId,
        uint256 normalDelay
    ) external returns (AvanaTimelock) {
        return _on(chainId, normalDelay);
    }
}
