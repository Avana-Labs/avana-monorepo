// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice One `(target, selector)` pair of the AvanaTimelock's `SHORT_ELIGIBLE` set or DAO-only cancel set, passed
/// to its constructor with the target's deterministic deployment address on the chain.
/// @custom:spec REQ-ACCESS-141, REQ-ACCESS-142, REQ-ACCESS-155, REQ-ACCESS-156, REQ-ACCESS-181
struct SelectorPair {
    address target;
    bytes4 selector;
}
