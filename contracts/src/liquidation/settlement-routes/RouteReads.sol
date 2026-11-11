// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ITetherFee} from "../../interfaces/external/tether/ITetherFee.sol";

/// @title RouteReads
/// @notice The static reads a swap route's constructor makes on the contracts it is given (pools, factories, wrappers,
/// peg modules, the Lock and the fee-switch probe of a token), each reported as success or failure instead of
/// reverting, so that every failed deployment check reverts with the route's own `InvalidRouteConfig` (REQ-ROUTE-045).
/// @dev A revert and a return shorter than the words read count as a failed read; a static call to an address without
/// code succeeds with no return data, so it fails the length check the same way. Each read copies at most the words it
/// decodes, so a contract returning a huge buffer cannot make the deployment pay for it. Used only in constructors.
/// @custom:spec REQ-ROUTE-008, REQ-ROUTE-045
library RouteReads {
    /// @notice Gas of the fee-switch probe: USDT's getter is one storage read.
    uint256 internal constant FEE_SWITCH_PROBE_GAS = 30_000;

    /// @notice Gas kept for the work after the probe returns.
    uint256 internal constant POST_CALL_GAS = 5000;

    /// @notice The first word, or the first three words, returned by a static call of `data` on `target`.
    /// @dev The read forwards all but 1/64 of the gas left; a read that fails for lack of gas fails the deployment
    /// check, which is the closed side.
    /// @param target Contract read.
    /// @param data Calldata.
    /// @param three True to read three words, false to read one; words not read are 0.
    /// @return ok The call succeeded and returned at least the words read.
    /// @return w The words (0 when `ok` is false).
    function words(
        address target,
        bytes memory data,
        bool three
    ) internal view returns (bool ok, uint256[3] memory w) {
        uint256 length = three ? 96 : 32;
        bytes memory ret;
        (ok, ret) = _staticRead(target, gasleft(), data, length);
        if (!ok || ret.length < length) return (false, w);
        // uint256 words decode without range checks, so a malformed value fails the caller's comparison, not here.
        if (three) {
            (w[0], w[1], w[2]) = abi.decode(ret, (uint256, uint256, uint256));
        } else {
            w[0] = abi.decode(ret, (uint256));
        }
    }

    /// @notice An address returned as the first word of a static call; a word with bits above 160 fails.
    /// @param target Contract read.
    /// @param data Calldata.
    /// @return ok The read succeeded and the word is an address.
    /// @return value The address (0 when `ok` is false).
    function addressOf(
        address target,
        bytes memory data
    ) internal view returns (bool ok, address value) {
        bytes memory ret;
        (ok, ret) = _staticRead(target, gasleft(), data, 32);
        if (!ok || ret.length < 32 || abi.decode(ret, (uint256)) >> 160 != 0) return (false, address(0));
        // A word with no bit above 160 decodes as an address without reverting.
        value = abi.decode(ret, (address));
    }

    /// @notice Whether `token` has a transfer-fee switch an issuer can turn on: it answers USDT's
    /// `basisPointsRate()` with one word, whatever the current rate.
    /// @dev A switch that is off today can be turned on at any time, so the answer, not the rate, decides. The probe
    /// runs with `FEE_SWITCH_PROBE_GAS`; with less than `⌈64 × G / 63⌉ + POST_CALL_GAS` gas left before it the token
    /// counts as having a switch, so a deployment sent with too little gas can never read a starved probe as "no
    /// switch" and the route is refused instead.
    /// @param token The token probed.
    /// @return switchable True when the getter answers with exactly one word, or when the probe could not get its gas.
    function hasFeeSwitch(
        address token
    ) internal view returns (bool switchable) {
        if (gasleft() < (64 * FEE_SWITCH_PROBE_GAS + 62) / 63 + POST_CALL_GAS) return true;
        (bool ok, bytes memory ret) =
            _staticRead(token, FEE_SWITCH_PROBE_GAS, abi.encodeCall(ITetherFee.basisPointsRate, ()), 64);
        switchable = ok && ret.length == 32;
    }

    /// @notice Static call with explicit gas `callGas`, copying at most `maxLength` bytes of return data.
    /// @return ok The call did not revert.
    /// @return ret Return data, truncated to `maxLength`.
    function _staticRead(
        address target,
        uint256 callGas,
        bytes memory data,
        uint256 maxLength
    ) private view returns (bool ok, bytes memory ret) {
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
}
