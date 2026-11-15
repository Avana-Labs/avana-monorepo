// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {UniswapV3IntegrationFixture} from "../utils/fixtures/UniswapV3IntegrationFixture.sol";

/// @notice The NFPM removal of `ClNfpmLPVault` (shared by Uniswap v3 and Slipstream) refuses an amount below each
/// minimum, token0 included, when the position manager skips its own check.
/// forge-config: default.isolate = false
contract ClNfpmLPVaultUnitTest is UniswapV3IntegrationFixture {
    // TEST-237 verifies: REQ-AMM-CORE-007, SPEC-BACK-008
    function test_TEST_237_belowMinimumOnToken0() public {
        bytes32 key = _pledge1(alice, 1e12);
        nfpm.setOverride(true, 5, 7);
        _lock();
        vm.prank(coll);
        vm.expectRevert(abi.encodeWithSelector(BelowMinimum.selector, uint256(0), uint256(5), uint256(6)));
        vault.releaseToDepositor(key, 1e9, _vec(6, 0));
        _unlock();
    }
}
