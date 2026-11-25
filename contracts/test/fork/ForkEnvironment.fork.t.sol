// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaTest} from "../utils/AvanaTest.sol";
import {ForkConstants} from "../utils/fixtures/ForkConstants.sol";

/// @title ForkEnvironmentForkTest
/// @notice `TEST-003`: each fork profile runs at the block committed in `ForkConstants`. A run with a block override
/// fails here on purpose, so a result produced at another block is never mistaken for one at the pin. Skipped without
/// the chain's RPC or while its pin is 0.
/// @dev Run with `FOUNDRY_PROFILE=fork forge test --match-contract ForkEnvironmentForkTest`.
contract ForkEnvironmentForkTest is AvanaTest {
    // TEST-003 verifies: Q-074
    function test_TEST_003_ethereumForkBlockEqualsPinnedConstant() public {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0 || ForkConstants.MAINNET_FORK_BLOCK == 0) vm.skip(true);
        vm.createSelectFork(rpc, ForkConstants.mainnetForkBlock());
        assertEq(block.number, ForkConstants.MAINNET_FORK_BLOCK, "Ethereum fork block is the committed pin");
        assertEq(block.chainid, 1);
    }

    // TEST-003 verifies: Q-074
    function test_TEST_003_baseForkBlockEqualsPinnedConstant() public {
        string memory rpc = vm.envOr("RPC_BASE", string(""));
        if (bytes(rpc).length == 0 || ForkConstants.BASE_FORK_BLOCK == 0) vm.skip(true);
        vm.createSelectFork(rpc, ForkConstants.baseForkBlock());
        assertEq(block.number, ForkConstants.BASE_FORK_BLOCK, "Base fork block is the committed pin");
        assertEq(block.chainid, 8453);
    }
}
