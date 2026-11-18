// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice One `(target, selector)` pair of the AvanaTimelock's short-eligible or DAO-only cancel set.
struct SelectorPair {
    address target;
    bytes4 selector;
}
