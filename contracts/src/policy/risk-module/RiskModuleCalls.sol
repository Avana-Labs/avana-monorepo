// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleErrors} from "./IRiskModuleErrors.sol";
import {RiskModuleMath} from "./RiskModuleMath.sol";

/// @title RiskModuleCalls
/// @notice The gas-limited, bounded static reads of the RiskModule: the issuer probes and the sequencer-uptime feed.
/// @dev Both revert `InsufficientGas` unless the call can receive its full gas, so a starved probe never trips.
library RiskModuleCalls {
    /// @notice Static call with explicit gas, copying at most `maxLength` bytes of return data.
    /// @param maxLength Most bytes copied: the expected ABI length, plus one to see a longer answer.
    function staticRead(
        address target,
        uint256 callGas,
        bytes memory data,
        uint256 maxLength
    ) internal view returns (bool ok, bytes memory ret) {
        uint256 required = RiskModuleMath.gasFloor(callGas);
        // A probe that cannot receive its full gas reverts the whole call.
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (gasleft() < required) revert IRiskModuleErrors.InsufficientGas(gasleft(), required);
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

    /// @notice Static call with explicit gas `callGas` whose answer must be exactly one 32-byte word.
    /// @dev Copies at most 32 bytes, into scratch space, and refuses a longer answer.
    /// @return ok The call did not revert and returned exactly 32 bytes.
    /// @return word The answer when `ok`, 0 otherwise.
    function staticReadWord(
        address target,
        uint256 callGas,
        bytes memory data
    ) internal view returns (bool ok, uint256 word) {
        uint256 required = RiskModuleMath.gasFloor(callGas);
        // A probe that cannot receive its full gas reverts the whole call.
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (gasleft() < required) revert IRiskModuleErrors.InsufficientGas(gasleft(), required);
        // Solidity's call syntax copies the whole return buffer, and its decoder accepts a longer one.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            let success := staticcall(callGas, target, add(data, 0x20), mload(data), 0x00, 0x20)
            ok := and(success, eq(returndatasize(), 0x20))
            // A short answer leaves scratch bytes unwritten; the word is read only when exactly 32 arrived.
            word := mul(ok, mload(0x00))
        }
    }

    /// @notice The 32-byte word at byte `offset` of `b`, bounds-checked.
    /// @return ok `offset + 32 <= b.length`.
    /// @return word The word (0 when out of bounds).
    function wordAt(
        bytes memory b,
        uint256 offset
    ) internal pure returns (bool ok, uint256 word) {
        if (offset > b.length || b.length - offset < 32) return (false, 0);
        // abi.decode reverts on malformed data, which the sequencer read must report as down.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            word := mload(add(add(b, 0x20), offset))
        }
        ok = true;
    }
}
