// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IUniswapV4Integration} from "../../src/amm/uniswap-v4/IUniswapV4Integration.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {UniswapV4IntegrationFixture} from "../utils/fixtures/UniswapV4IntegrationFixture.sol";

/// @title UniswapV4IntegrationBlockTimeUnitTest
/// @notice The Uniswap v4 LPVault's block interval, fixed at deployment (`REQ-VAULT-155`), sizes the reference pool's
/// TWAP buffer check (`SPEC-ORC-022`): the consistency read needs `ceil(window / blockTime) + 1` observation slots. The
/// deployment checks are in `UniswapV4Integration.Guards`; this is the same suite as the Uniswap v3 LPVault's.
/// forge-config: default.isolate = false
contract UniswapV4IntegrationBlockTimeUnitTest is UniswapV4IntegrationFixture {
    function _deployAt(
        uint256 blockTime
    ) internal returns (IUniswapV4Integration v) {
        v = IUniswapV4Integration(
            deployCode(
                "UniswapV4Integration.sol:UniswapV4Integration",
                abi.encode(
                    INTEGRATION, coll, registry, address(lock), timelock, address(posm), address(factory), blockTime
                )
            )
        );
    }

    // TEST-264 verifies: SPEC-ORC-022, REQ-AMM-CORE-009, REQ-AMM-V4-005, REQ-VAULT-155
    /// @notice The fixture's reference pool has 200 slots and 756 s of 12 s observations. At 12 s blocks a 600 s
    /// window needs `ceil(600 / 12) + 1 = 51` slots and the read is available; the same pool read by an LPVault deployed
    /// for Base's 2 s blocks needs 301 and is unavailable, while a 60 s window (31 slots) is available there.
    function test_TEST_264_observationBufferFollowsTheBlockTime() public {
        _observe(ethRef, 60);
        uint256[] memory px = _vec(ETH_PRICE, ONE);
        (, bool ok) = vault.consistencyDeviation(M2, 600, px);
        assertTrue(ok, "12 s blocks: 51 of 200 slots");
        vm.chainId(8453);
        IUniswapV4Integration base = _deployAt(2);
        vm.prank(registry);
        base.bindMarket(
            M2,
            address(0),
            _poolId(ethKey),
            PositionShape(ShapeKind.TickRange, M2_LOWER, M2_UPPER),
            _bindData(ethKey, address(ethRef), ETH_PRICE, ONE)
        );
        (, ok) = base.consistencyDeviation(M2, 600, px);
        assertFalse(ok, "2 s blocks: 301 slots needed, 200 held");
        (, ok) = base.consistencyDeviation(M2, 60, px);
        assertTrue(ok, "2 s blocks, 60 s window: 31 slots");
    }

    // TEST-108 verifies: REQ-VAULT-155
    /// @notice On a chain Avana does not know, any interval in `[1, 12]` is taken as given.
    function testFuzz_TEST_108_anyIntervalUpTo12OnAnUnknownChain(
        uint256 blockTime
    ) public {
        blockTime = bound(blockTime, 1, 12);
        assertEq(_deployAt(blockTime).BLOCK_TIME(), blockTime);
    }
}
