// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracleErrors} from "./ILPOracleErrors.sol";
import {LPPriceMath} from "./LPPriceMath.sol";

/// @title LPOracleCalls
/// @notice The gas-guarded static read of every LPOracle external call and the bounded word reader that decodes its
/// return data (`SPEC-ORC-023`, `REQ-ORACLE-001`).
/// @dev `staticRead` requires `gasleft() >= ceil(64 * G / 63) + POST_CALL_GAS` before the call and otherwise reverts
/// `InsufficientGas`, so the call receives its full `G` whatever gas limit the caller chose; it copies at most
/// `maxLength` bytes of return data, so a source returning a huge buffer cannot make the caller pay for it. A revert,
/// a call to an address without code or a short return is reported as `ok = false` or a short buffer; it never
/// reverts. `wordAt` reads one 32-byte word at a byte offset with a bounds check, and `wordArray` checks a whole
/// `uint256[]` encoding once and exposes its words in place, so a malformed encoding is a failed read and never an
/// out-of-bounds read or a decoder revert. Example: a 50,000-gas feed read needs 55,794 gas left.
/// @custom:spec SPEC-ORC-023, REQ-ORACLE-001, REQ-ORACLE-039, REQ-ORACLE-061, REQ-ORACLE-102
library LPOracleCalls {
    /// @notice Static call with explicit gas `callGas`, copying at most `maxLength` bytes of return data.
    /// @dev Reverts `InsufficientGas(gasleft(), required)` before the call when less than `gasForCall(callGas)` is
    /// left. `ret.length` is `min(returndatasize, maxLength)`.
    /// @param target Contract read.
    /// @param callGas Explicit gas `G_k` of the read.
    /// @param data Calldata.
    /// @param maxLength ABI length of the expected return data.
    /// @return ok The call did not revert.
    /// @return ret Return data, truncated to `maxLength`.
    /// @custom:spec SPEC-ORC-023, REQ-ORACLE-001, REQ-ORACLE-102
    function staticRead(
        address target,
        uint256 callGas,
        bytes memory data,
        uint256 maxLength
    ) internal view returns (bool ok, bytes memory ret) {
        uint256 required = LPPriceMath.gasForCall(callGas);
        // The pre-call gas check of SPEC-ORC-023: a read that cannot receive its full gas reverts the whole call.
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

    /// @notice The 32-byte word at byte `offset` of `b`.
    /// @return ok `offset + 32 <= b.length`.
    /// @return word The word (0 when out of bounds).
    /// @custom:spec REQ-ORACLE-001, REQ-ORACLE-061
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
    /// @custom:spec REQ-ORACLE-001, REQ-ORACLE-061
    function uintAt(
        bytes memory b,
        uint256 offset,
        uint256 max
    ) internal pure returns (bool ok, uint256 value) {
        (ok, value) = wordAt(b, offset);
        if (!ok || value > max) return (false, 0);
    }

    /// @notice The word at byte `offset` of `b` read as a signed value of `bits` bits (`bits` in `[8, 256]`): for
    /// fewer than 256 bits the word must be a valid sign extension.
    /// @custom:spec REQ-ORACLE-001, REQ-ORACLE-061
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

    /// @notice The ABI encoding of a `uint256[]` of exactly `count` words in `b`, as a view of its words (no copy).
    /// @return ok `b` is exactly `[0x20, count, w_0, ..., w_{count-1}]`.
    /// @return values The words, sharing `b`'s memory (empty when `ok` is false).
    /// @custom:spec REQ-ORACLE-001, REQ-ORACLE-061
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
