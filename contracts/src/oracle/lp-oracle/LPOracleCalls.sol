// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracleErrors} from "./ILPOracleErrors.sol";
import {LPPriceMath} from "./LPPriceMath.sol";

/// @title LPOracleCalls
/// @notice Gas-guarded static reads and bounded word decoding for every LPOracle external call.
/// @dev A malformed return is a failed read, never a revert; only a read short of its gas reverts.
library LPOracleCalls {
    /// @notice Static call with explicit gas `callGas`, copying at most `maxLength` bytes of return data.
    /// @dev Reverts `InsufficientGas` before the call unless the full `callGas` can be forwarded.
    /// @param maxLength ABI length of the expected return data.
    function staticRead(
        address target,
        uint256 callGas,
        bytes memory data,
        uint256 maxLength
    ) internal view returns (bool ok, bytes memory ret) {
        uint256 required = LPPriceMath.gasForCall(callGas);
        // A read that cannot receive its full gas reverts the whole call.
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (gasleft() < required) revert ILPOracleErrors.InsufficientGas(gasleft(), required);
        ret = new bytes(maxLength);
        // A bounded static call: Solidity's own call syntax copies the whole return buffer.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            ok := staticcall(callGas, target, add(data, 0x20), mload(data), add(ret, 0x20), maxLength)
            let size := returndatasize()
            if gt(size, maxLength) { size := maxLength }
            mstore(ret, size)
        }
    }

    /// @notice The 32-byte word at byte `offset` of `b`; `ok` false when out of bounds.
    function wordAt(
        bytes memory b,
        uint256 offset
    ) internal pure returns (bool ok, uint256 word) {
        if (offset > b.length || b.length - offset < 32) return (false, 0);
        // A bounds-checked word read: abi.decode reverts on malformed data, which no view may do.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            word := mload(add(add(b, 0x20), offset))
        }
        ok = true;
    }

    /// @notice The word at byte `offset` of `b` when it is at most `max`.
    function uintAt(
        bytes memory b,
        uint256 offset,
        uint256 max
    ) internal pure returns (bool ok, uint256 value) {
        (ok, value) = wordAt(b, offset);
        if (!ok || value > max) return (false, 0);
    }

    /// @notice The word at byte `offset` of `b` as a signed `bits`-bit value; it must be a valid sign extension.
    function intAt(
        bytes memory b,
        uint256 offset,
        uint256 bits
    ) internal pure returns (bool ok, int256 value) {
        uint256 word;
        (ok, word) = wordAt(b, offset);
        // Reinterpreting the 256-bit word as two's complement is the ABI encoding of a signed value.
        // forge-lint: disable-next-line(unsafe-typecast)
        value = int256(word);
        if (!ok) return (false, 0);
        if (bits >= 256) return (true, value);
        int256 bound = int256(1) << (bits - 1);
        if (value < -bound || value >= bound) return (false, 0);
    }

    /// @notice A `uint256[]` encoding of exactly `count` words in `b`, as a view of its words (no copy).
    function wordArray(
        bytes memory b,
        uint256 count
    ) internal pure returns (bool ok, uint256[] memory values) {
        if (count > type(uint32).max || b.length != 64 + 32 * count) return (false, values);
        // Reads the offset and length words, then points `values` at the length word: `b` is laid out as the array.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            ok := and(eq(mload(add(b, 0x20)), 0x20), eq(mload(add(b, 0x40)), count))
            if ok { values := add(b, 0x40) }
        }
    }
}
