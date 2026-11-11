// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title RawAnswer
/// @notice Answers every call with a fixed raw byte string, or reverts, or burns all its gas: the hostile and malformed
/// answers a route's constructor reads must survive (a word with bits above 160 for an address, too few bytes, too
/// many bytes, a revert, no return at all).
contract RawAnswer {
    bytes internal _answer;
    bool public reverts;
    bool public burns;

    function set(
        bytes calldata answer
    ) external {
        _answer = answer;
    }

    function setReverts(
        bool on
    ) external {
        reverts = on;
    }

    function setBurns(
        bool on
    ) external {
        burns = on;
    }

    fallback() external {
        if (reverts) revert("raw answer");
        if (burns) {
            uint256 x = 0;
            while (gasleft() > 0) {
                ++x;
            }
        }
        bytes memory a = _answer;
        assembly ("memory-safe") {
            return(add(a, 0x20), mload(a))
        }
    }
}
