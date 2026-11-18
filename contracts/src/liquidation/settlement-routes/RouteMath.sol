// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ITetherFee} from "../../interfaces/external/tether/ITetherFee.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title RouteMath
/// @notice Arithmetic of the swap routes: the LitePSM gem amount a `PegModule` route buys with the DAI it holds.
/// @dev LitePSM cost of `g` gem units: `g × c + ⌊g × c × tout / 10¹⁸⌋` DAI wei, `c = 10^(18 − gemDecimals)`.
library RouteMath {
    /// @notice Gas of the fee-switch probe: USDT's getter is one storage read.
    uint256 internal constant FEE_SWITCH_PROBE_GAS = 30_000;

    uint256 internal constant POST_CALL_GAS = 5000;

    /// @notice The first word, or the first three words, returned by a static call of `data` on `target`.
    /// @dev A read that fails for lack of gas fails the deployment check, which is the closed side.
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

    /// @notice Whether `token` has a transfer-fee switch: it answers USDT's `basisPointsRate()` with one word.
    /// @dev Without enough gas for the probe the token counts as having a switch, so a starved probe cannot pass.
    function hasFeeSwitch(
        address token
    ) internal view returns (bool switchable) {
        if (gasleft() < (64 * FEE_SWITCH_PROBE_GAS + 62) / 63 + POST_CALL_GAS) return true;
        (bool ok, bytes memory ret) =
            _staticRead(token, FEE_SWITCH_PROBE_GAS, abi.encodeCall(ITetherFee.basisPointsRate, ()), 64);
        switchable = ok && ret.length == 32;
    }

    function _staticRead(
        address target,
        uint256 callGas,
        bytes memory data,
        uint256 maxLength
    ) internal view returns (bool ok, bytes memory ret) {
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

    /// @notice WAD, the LitePSM fee unit.
    uint256 internal constant WAD = 1e18;

    /// @notice Fees at or above this buy nothing; keeps `(WAD + tout) × c` below 2²⁵⁶.
    uint256 internal constant MAX_TOUT = 1e36;

    /// @notice The largest gem amount `g` with `cost(g) ≤ dai`.
    /// @dev The floored estimate always fits and estimate + 2 never does, so only estimate + 1 is checked.
    /// @param conversion `10^(18 − gemDecimals)`.
    /// @return gemAmt Gem units to buy; 0 when `tout ≥ MAX_TOUT`.
    function litePsmGemAmt(
        uint256 dai,
        uint256 tout,
        uint256 conversion
    ) internal pure returns (uint256 gemAmt) {
        if (tout >= MAX_TOUT) return 0;
        gemAmt = Math.mulDiv(dai, WAD, (WAD + tout) * conversion);
        if (litePsmCost(gemAmt + 1, tout, conversion) <= dai) gemAmt += 1;
    }

    /// @notice LitePSM DAI cost, in wei, of `gemAmt` gem units.
    function litePsmCost(
        uint256 gemAmt,
        uint256 tout,
        uint256 conversion
    ) internal pure returns (uint256 daiInWad) {
        uint256 gemAmt18 = gemAmt * conversion;
        daiInWad = gemAmt18 + Math.mulDiv(gemAmt18, tout, WAD);
    }
}
