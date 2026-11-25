// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Vm} from "forge-std/Vm.sol";

/// @title ForkConstants
/// @notice The pinned fork blocks of the Ethereum and Base fork profiles (`TEST-003`). A pin changes only by a
/// reviewed commit of this file, so every fork result can be re-run at the block it was produced on, and CI keys its
/// RPC response cache (`~/.foundry/cache/rpc`) on this file's hash.
/// @dev A block is chosen with `cast block-number --rpc-url mainnet` (or `base`) on an archive endpoint, then committed
/// here. The environment variables `MAINNET_FORK_BLOCK` and `BASE_FORK_BLOCK` override a pin for local experiments
/// only; CI never sets them. A pin of 0 means the profile has no block yet: fork suites skip unless an override is
/// given.
library ForkConstants {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Pinned Ethereum mainnet fork block. PIN: replace 0 with the chosen block number.
    uint256 internal constant MAINNET_FORK_BLOCK = 0;

    /// @notice Pinned Base fork block. PIN: replace 0 with the chosen block number.
    uint256 internal constant BASE_FORK_BLOCK = 0;

    /// @notice The Ethereum fork block a suite selects: the `MAINNET_FORK_BLOCK` override if set, else the pin.
    function mainnetForkBlock() internal view returns (uint256) {
        return VM.envOr("MAINNET_FORK_BLOCK", MAINNET_FORK_BLOCK);
    }

    /// @notice The Base fork block a suite selects: the `BASE_FORK_BLOCK` override if set, else the pin.
    function baseForkBlock() internal view returns (uint256) {
        return VM.envOr("BASE_FORK_BLOCK", BASE_FORK_BLOCK);
    }
}
