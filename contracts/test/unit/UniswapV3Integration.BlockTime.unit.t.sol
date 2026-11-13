// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {UniswapV3Integration} from "../../src/amm/uniswap-v3/UniswapV3Integration.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {UniswapV3IntegrationFixture} from "../utils/fixtures/UniswapV3IntegrationFixture.sol";
import {UniswapV3IntegrationChainHarness} from "../utils/harness/UniswapV3IntegrationHarness.sol";

/// @title UniswapV3IntegrationBlockTimeUnitTest
/// @notice The Uniswap v3 LPVault's block interval (`REQ-AMM-V3-012`): fixed at deployment, checked against the chain,
/// and used by the TWAP observation check (`SPEC-ORC-022`).
/// forge-config: default.isolate = false
contract UniswapV3IntegrationBlockTimeUnitTest is UniswapV3IntegrationFixture {
    uint256 internal constant BOUND = 77;

    function _bindings() internal view returns (address[6] memory b) {
        b = [coll, registry, address(lock), timelock, address(nfpm), address(v3Factory)];
    }

    function _deploy(
        uint256 blockTime
    ) internal returns (UniswapV3IntegrationChainHarness) {
        return new UniswapV3IntegrationChainHarness(_bindings(), v3Factory.poolInitCodeHash(), blockTime);
    }

    function _deployExpectRevert(
        uint256 blockTime
    ) internal {
        address[6] memory b = _bindings();
        bytes32 h = v3Factory.poolInitCodeHash();
        vm.expectRevert(InvalidDeployment.selector);
        new UniswapV3IntegrationChainHarness(b, h, blockTime);
    }

    // TEST-108 verifies: REQ-AMM-V3-012
    /// @notice 0 and anything above 12 s are refused on every chain; a chain Avana knows takes only its own interval.
    function test_TEST_108_blockTimeFailsClosed() public {
        _deployExpectRevert(0);
        _deployExpectRevert(13);
        assertEq(_deploy(1).BLOCK_TIME(), 1, "an unknown chain takes any interval in [1, 12]");
        vm.chainId(1);
        _deployExpectRevert(2);
        assertEq(_deploy(12).BLOCK_TIME(), 12, "Ethereum: 12 s");
        vm.chainId(11_155_111);
        _deployExpectRevert(2);
        assertEq(_deploy(12).BLOCK_TIME(), 12, "Sepolia: 12 s");
        vm.chainId(8453);
        _deployExpectRevert(12);
        assertEq(_deploy(2).BLOCK_TIME(), 2, "Base: 2 s");
        vm.chainId(84_532);
        _deployExpectRevert(12);
        assertEq(_deploy(2).BLOCK_TIME(), 2, "Base Sepolia: 2 s");
        vm.chainId(10);
        _deployExpectRevert(1);
        assertEq(_deploy(2).BLOCK_TIME(), 2, "OP Mainnet: 2 s");
    }

    // TEST-264 verifies: REQ-AMM-V3-012, SPEC-ORC-022, REQ-AMM-CORE-009
    /// @notice On Base (2 s blocks) a 1,800 s window needs ceil(1,800 / 2) + 1 = 901 observations: 900 leave the check
    /// unavailable, 901 make it available; on Ethereum 151 suffice.
    function test_TEST_264_observationBufferFollowsTheBlockTime() public {
        vm.chainId(8453);
        UniswapV3IntegrationChainHarness base = _deploy(2);
        vm.prank(registry);
        base.bindMarket(
            BOUND, address(pool500), bytes32(0), PositionShape(ShapeKind.TickRange, -50, 50), abi.encode(1e8, 1e8)
        );
        uint256[] memory peg = new uint256[](2);
        (peg[0], peg[1]) = (1e8, 1e8);
        pool500.setObservations(900, 0, 0, 0, 1, false);
        (, bool ok) = base.consistencyDeviation(BOUND, 1800, peg);
        assertFalse(ok, "900 observations do not cover 1,800 s at 2 s blocks");
        pool500.setObservations(901, 0, 1800 * 3, 0, 1, false);
        uint256 dev;
        (dev, ok) = base.consistencyDeviation(BOUND, 1800, peg);
        assertTrue(ok, "901 do");
        assertEq(dev, 3, "mean tick 3");
        vm.chainId(1);
        UniswapV3IntegrationChainHarness eth = _deploy(12);
        vm.prank(registry);
        eth.bindMarket(
            BOUND, address(pool500), bytes32(0), PositionShape(ShapeKind.TickRange, -50, 50), abi.encode(1e8, 1e8)
        );
        pool500.setObservations(151, 0, 0, 0, 1, false);
        (, ok) = eth.consistencyDeviation(BOUND, 1800, peg);
        assertTrue(ok, "151 at 12 s blocks");
    }

    // TEST-108 verifies: REQ-AMM-V3-012
    function testFuzz_TEST_108_anyIntervalUpTo12OnAnUnknownChain(
        uint256 blockTime
    ) public {
        blockTime = bound(blockTime, 1, 12);
        UniswapV3Integration v = _deploy(blockTime);
        assertEq(v.BLOCK_TIME(), blockTime);
    }
}
