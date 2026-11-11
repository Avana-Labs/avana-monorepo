// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title BytecodeInspector
/// @notice Reads compiled EVM code the way the CI bytecode check does: walks the opcodes (skipping PUSH data), lists
/// the dispatcher's selectors (`PUSH4 s` followed by `EQ`, or by `GT` for a binary-search pivot) and finds opcodes.
/// @dev Every range is half-open `[from, to)`. A data blob inside the code (for example an embedded creation code) is
/// excluded by scanning around it with two ranges.
library BytecodeInspector {
    uint8 internal constant OP_PUSH1 = 0x60;
    uint8 internal constant OP_PUSH4 = 0x63;
    uint8 internal constant OP_PUSH32 = 0x7f;
    uint8 internal constant OP_EQ = 0x14;
    uint8 internal constant OP_GT = 0x11;

    /// @notice Dispatcher selectors of `code[from:to]`, without repeats.
    function dispatcherSelectors(
        bytes memory code,
        uint256 from,
        uint256 to
    ) internal pure returns (bytes4[] memory selectors) {
        bytes4[] memory found = new bytes4[](64);
        uint256 n = 0;
        uint256 i = from;
        while (i < to) {
            uint8 op = uint8(code[i]);
            if (op == OP_PUSH4 && i + 5 < to) {
                uint8 next = uint8(code[i + 5]);
                if (next == OP_EQ || next == OP_GT) {
                    bytes4 s = _read4(code, i + 1);
                    if (!_contains(found, n, s)) found[n++] = s;
                }
            }
            i += _width(op);
        }
        selectors = new bytes4[](n);
        for (uint256 k = 0; k < n; ++k) {
            selectors[k] = found[k];
        }
    }

    /// @notice Whether any `PUSH4` constant of `code[from:to]` equals `selector`.
    function pushesSelector(
        bytes memory code,
        uint256 from,
        uint256 to,
        bytes4 selector
    ) internal pure returns (bool) {
        uint256 i = from;
        while (i < to) {
            uint8 op = uint8(code[i]);
            if (op == OP_PUSH4 && i + 4 < to) {
                if (_read4(code, i + 1) == selector) return true;
            }
            i += _width(op);
        }
        return false;
    }

    /// @notice Whether opcode `target` occurs in `code[from:to]` as an instruction (not as PUSH data).
    function hasOpcode(
        bytes memory code,
        uint256 from,
        uint256 to,
        uint8 target
    ) internal pure returns (bool) {
        uint256 i = from;
        while (i < to) {
            uint8 op = uint8(code[i]);
            if (op == target) return true;
            i += _width(op);
        }
        return false;
    }

    /// @notice First index of `needle` in `haystack`, or `type(uint256).max`.
    function indexOf(
        bytes memory haystack,
        bytes memory needle
    ) internal pure returns (uint256) {
        if (needle.length == 0 || needle.length > haystack.length) return type(uint256).max;
        for (uint256 i = 0; i + needle.length <= haystack.length; ++i) {
            uint256 k = 0;
            while (k < needle.length && haystack[i + k] == needle[k]) {
                ++k;
            }
            if (k == needle.length) return i;
        }
        return type(uint256).max;
    }

    function _read4(
        bytes memory code,
        uint256 at
    ) private pure returns (bytes4) {
        return bytes4(
            (uint32(uint8(code[at])) << 24) | (uint32(uint8(code[at + 1])) << 16) | (uint32(uint8(code[at + 2])) << 8)
                | uint32(uint8(code[at + 3]))
        );
    }

    function _width(
        uint8 op
    ) private pure returns (uint256) {
        return op >= OP_PUSH1 && op <= OP_PUSH32 ? 1 + uint256(op - OP_PUSH1 + 1) : 1;
    }

    function _contains(
        bytes4[] memory list,
        uint256 n,
        bytes4 s
    ) private pure returns (bool) {
        for (uint256 k = 0; k < n; ++k) {
            if (list[k] == s) return true;
        }
        return false;
    }
}
