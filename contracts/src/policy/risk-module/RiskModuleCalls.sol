// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleErrors} from "./IRiskModuleErrors.sol";
import {RiskModuleMath} from "./RiskModuleMath.sol";

/// @title RiskModuleCalls
/// @notice The gas-limited, bounded static reads of the RiskModule: the issuer probes (SPEC-BRK-003, `staticReadWord`)
/// and the sequencer-uptime feed (REQ-RISK-081, `staticRead`).
/// @dev Both reads require `gasleft() >= ceil(64 * G / 63) + POST_CALL_GAS` before the call and otherwise revert
/// `InsufficientGas`, so the probe receives its full `G` whatever gas the caller chose and a starved probe can never be
/// read as an issuer action (REQ-RISK-089, AMMN-GAS-04). Each copies a bounded number of return-data bytes, so a token
/// returning a huge buffer cannot make the caller pay for it. A revert, a call to an address without code or a
/// return of the wrong length is reported as `ok = false` or a short buffer and never reverts. The same pattern as the
/// LPOracle's static reads (SPEC-ORC-023).
/// @custom:spec REQ-RISK-089, SPEC-BRK-003, REQ-RISK-081, SPEC-ORC-023
library RiskModuleCalls {
    /// @notice Static call with explicit gas `callGas`, copying at most `maxLength` bytes of return data; a longer
    /// answer is truncated to `maxLength`, so a caller needing exactly `n` bytes reads `n + 1` and checks the length.
    /// @param target Contract read.
    /// @param callGas Explicit gas of the read.
    /// @param data Calldata.
    /// @param maxLength Most bytes copied: the expected ABI length, plus one to see a longer answer.
    /// @return ok The call did not revert.
    /// @return ret Return data, truncated to `maxLength`.
    /// @custom:spec REQ-RISK-089
    function staticRead(
        address target,
        uint256 callGas,
        bytes memory data,
        uint256 maxLength
    ) internal view returns (bool ok, bytes memory ret) {
        uint256 required = RiskModuleMath.gasFloor(callGas);
        // The pre-call gas check of REQ-RISK-089: a probe that cannot receive its full gas reverts the whole call.
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

    /// @notice Static call with explicit gas `callGas` whose answer must be exactly one 32-byte word (SPEC-BRK-003).
    /// @dev Copies at most 32 bytes, into scratch space, whatever the answer's length, and checks `returndatasize()`
    /// after the call: a longer answer is refused even when its first word is clear, and its extra bytes are never
    /// copied.
    /// @param target Contract read.
    /// @param callGas Explicit gas of the read.
    /// @param data Calldata.
    /// @return ok The call did not revert and returned exactly 32 bytes.
    /// @return word The answer when `ok`, 0 otherwise.
    /// @custom:spec REQ-RISK-089, SPEC-BRK-003
    function staticReadWord(
        address target,
        uint256 callGas,
        bytes memory data
    ) internal view returns (bool ok, uint256 word) {
        uint256 required = RiskModuleMath.gasFloor(callGas);
        // The pre-call gas check of REQ-RISK-089: a probe that cannot receive its full gas reverts the whole call.
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (gasleft() < required) revert IRiskModuleErrors.InsufficientGas(gasleft(), required);
        // A one-word static call: Solidity's own call syntax copies the whole return buffer, and its decoder accepts
        // a longer one.
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
    /// @custom:spec REQ-RISK-081
    function wordAt(
        bytes memory b,
        uint256 offset
    ) internal pure returns (bool ok, uint256 word) {
        if (offset > b.length || b.length - offset < 32) return (false, 0);
        // A bounds-checked word read: abi.decode reverts on malformed data, which the sequencer read must report as
        // down (REQ-RISK-081).
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            word := mload(add(add(b, 0x20), offset))
        }
        ok = true;
    }
}
