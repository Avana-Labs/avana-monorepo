// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../amm/concentrated-liquidity/ClPriceMath.sol";
import {IUniswapV3Pool} from "../../interfaces/external/uniswap/IUniswapV3Pool.sol";
import {OracleConfig} from "../../types/OracleConfig.sol";
import {SecondSource} from "../../types/SecondSource.sol";
import {SecondSourceKind} from "../../types/SecondSourceKind.sol";
import {LPOracleCalls} from "./LPOracleCalls.sol";
import {LPOracleStorage} from "./LPOracleStorage.sol";

/// @title LPOracleCLPool
/// @notice The concentrated-liquidity pricing module's market storage and its pool reads: the market's pool and exact
/// range fixed at `initialize`, the pool's `slot0` lock flag and observation cardinality, its token pair and tick
/// spacing, and the mean tick of `observe([window, 0])` (2.10 Concentrated-liquidity pricing).
/// @dev ERC-7201 namespace `avana.storage.LPOracleCL`, next to the base's `avana.storage.LPOracle` in the same proxy.
/// Every read is a gas-guarded static call (`SPEC-ORC-023`) that copies one byte more than the expected return, so a
/// short, long or malformed answer is a failed read and never a decoder revert. `slot0` has 7 words on Uniswap v3 and 6
/// on Aerodrome Slipstream; the implementation fixes which at deployment (`SLOT0_WORDS`), and only the lock flag
/// (the last word) and the observation cardinality (word 3) are read, never the pool's price or tick (`REQ-ORACLE-011`).
/// @custom:spec REQ-ORACLE-011, REQ-ORACLE-014, REQ-ORACLE-103, REQ-ORACLE-104, REQ-AMM-V3-003, REQ-AMM-SLIP-003, SPEC-ORC-010, SPEC-ORC-023
abstract contract LPOracleCLPool is LPOracleStorage {
    /// @notice The market's pool and exact range, and the range's square-root ratios computed once at `initialize`.
    /// @custom:storage-location erc7201:avana.storage.LPOracleCL
    struct ClLayout {
        address pool;
        int24 tickLower;
        int24 tickUpper;
        int24 tickSpacing;
        uint160 sqrtLower;
        uint160 sqrtUpper;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("avana.storage.LPOracleCL")) - 1)) & ~bytes32(uint256(0xff)).
    bytes32 private constant _CL_SLOT = 0xb7c40d03a80aa05aa5c63763d6d3607d29246f15ca457871c1bef2104cb45600;

    /// @dev Bytes of one ABI word.
    uint256 private constant _W = 32;
    /// @dev Return length of `observe([window, 0])`: two arrays of two words with their offsets and lengths.
    uint256 private constant _OBSERVE_LENGTH = 8 * _W;

    /// @dev Number of words `slot0()` returns: 7 on Uniswap v3, 6 on Aerodrome Slipstream (`REQ-AMM-V3-003`).
    uint8 internal immutable _SLOT0_WORDS;

    /// @notice The configuration words the module's listing checks read (`REQ-ORACLE-055`, `REQ-ORACLE-100`).
    struct ClListingInputs {
        uint32 twapWindow;
        uint16 consistencyToleranceBps;
        uint16 twapMinObservations;
        uint8 pairs;
        SecondSourceKind[2] kinds;
        bytes32[2] poolRefs;
    }

    /// @notice Fixes the `slot0` layout of the AMM protocol this implementation prices.
    /// @dev Reverts `MarketMismatch(0)` for any layout other than 6 or 7 words.
    /// @param slot0Words 7 for Uniswap v3, 6 for Aerodrome Slipstream.
    /// @custom:spec REQ-AMM-V3-003, REQ-AMM-SLIP-003
    constructor(
        uint8 slot0Words
    ) {
        if (slot0Words != 6 && slot0Words != 7) revert MarketMismatch(0);
        _SLOT0_WORDS = slot0Words;
    }

    /// @dev The words of `config` the module's listing checks read.
    function _listingInputs(
        OracleConfig calldata config
    ) internal pure returns (ClListingInputs memory x) {
        (x.twapWindow, x.consistencyToleranceBps, x.twapMinObservations) =
        (config.twapWindow, config.consistencyToleranceBps, config.twapMinObservations);
        uint256 n = config.tokens.length < 2 ? config.tokens.length : 2;
        // n <= 2.
        // forge-lint: disable-next-line(unsafe-typecast)
        x.pairs = uint8(n);
        for (uint256 i = 0; i < n; ++i) {
            SecondSource calldata src = config.tokens[i].secondSource;
            (x.kinds[i], x.poolRefs[i]) = (src.kind, src.poolRef);
        }
    }

    /// @notice Words of the pool's `slot0()` return this implementation decodes: 7 (Uniswap v3) or 6 (Slipstream).
    /// @dev The implementation's constructor requires its three logic contracts to report the same value.
    /// @return words The layout fixed at deployment.
    /// @custom:spec REQ-AMM-V3-003, REQ-AMM-SLIP-003
    function SLOT0_WORDS() external view returns (uint8 words) {
        words = _SLOT0_WORDS;
    }

    /// @dev The module's ERC-7201 namespace.
    function _cl() internal pure returns (ClLayout storage c) {
        // ERC-7201 namespaced storage: the slot is a compile-time constant.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            c.slot := _CL_SLOT
        }
    }

    /// @dev `slot0()` of `pool`: whether the read succeeded with exactly `_SLOT0_WORDS` words, a valid boolean lock flag
    /// and a cardinality within `uint16`; the observation cardinality (word 3) and `unlocked` (the last word).
    /// @custom:spec REQ-ORACLE-103, REQ-AMM-V3-003, REQ-AMM-SLIP-003
    function _slot0(
        address pool
    ) internal view returns (bool ok, uint16 cardinality, bool unlocked) {
        uint256 length = uint256(_SLOT0_WORDS) * _W;
        bytes memory ret;
        (ok, ret) = LPOracleCalls.staticRead(
            pool, POOL_CALL_GAS, abi.encodeWithSelector(IUniswapV3Pool.slot0.selector), length + 1
        );
        if (!ok || ret.length != length) return (false, 0, false);
        uint256 card = 0;
        uint256 flag = 0;
        (ok, card) = LPOracleCalls.uintAt(ret, 3 * _W, type(uint16).max);
        if (ok) (ok, flag) = LPOracleCalls.uintAt(ret, length - _W, 1);
        if (!ok) return (false, 0, false);
        // card <= type(uint16).max is checked by uintAt above.
        // forge-lint: disable-next-line(unsafe-typecast)
        (cardinality, unlocked) = (uint16(card), flag == 1);
    }

    /// @dev One address word of `pool` (`token0()` or `token1()`), `ok` false for a failed or malformed read.
    function _poolAddress(
        address pool,
        bytes4 selector,
        uint256 callGas
    ) internal view returns (bool ok, address value) {
        bytes memory ret;
        (ok, ret) = LPOracleCalls.staticRead(pool, callGas, abi.encodeWithSelector(selector), _W + 1);
        uint256 word = 0;
        if (ok && ret.length == _W) (ok, word) = LPOracleCalls.uintAt(ret, 0, type(uint160).max);
        else ok = false;
        value = address(uint160(word));
    }

    /// @dev `tickSpacing()` of `pool`, `ok` false for a failed or malformed read or a spacing outside `int24`.
    function _tickSpacing(
        address pool
    ) internal view returns (bool ok, int24 spacing) {
        bytes memory ret;
        (ok, ret) = LPOracleCalls.staticRead(
            pool, CONFIG_CALL_GAS, abi.encodeWithSelector(IUniswapV3Pool.tickSpacing.selector), _W + 1
        );
        int256 value = 0;
        if (ok && ret.length == _W) (ok, value) = LPOracleCalls.intAt(ret, 0, 24);
        else ok = false;
        // intAt checked that the word is a sign-extended int24.
        // forge-lint: disable-next-line(unsafe-typecast)
        spacing = int24(value);
    }

    /// @dev Arithmetic mean tick of `pool` over `window` seconds from `observe([window, 0])`, rounded toward negative
    /// infinity as Uniswap's `OracleLibrary.consult` (`SPEC-ORC-010`); `ok` false for a zero window, a failed read
    /// (including the pool's `OLD` revert when its buffer does not cover the window), a malformed return or a mean
    /// outside `[MIN_TICK, MAX_TICK]`. The cumulative difference wraps at 56 bits, as the pool's own arithmetic does.
    /// @custom:spec SPEC-ORC-010, REQ-ORACLE-014
    function _meanTick(
        address pool,
        uint32 window
    ) internal view returns (bool ok, int24 tick) {
        if (window == 0) return (false, 0);
        uint32[] memory ago = new uint32[](2);
        ago[0] = window;
        bytes memory ret;
        (ok, ret) = LPOracleCalls.staticRead(
            pool, POOL_CALL_GAS, abi.encodeWithSelector(IUniswapV3Pool.observe.selector, ago), _OBSERVE_LENGTH + 1
        );
        if (!ok || ret.length != _OBSERVE_LENGTH || !_observeShape(ret)) return (false, 0);
        int256 c0 = 0;
        int256 c1 = 0;
        (ok, c0) = LPOracleCalls.intAt(ret, 3 * _W, 56);
        if (ok) (ok, c1) = LPOracleCalls.intAt(ret, 4 * _W, 56);
        if (!ok) return (false, 0);
        (ok, tick) = _meanOf(c0, c1, window);
    }

    /// @dev `SPEC-ORC-010`'s mean tick of two tick cumulatives over `window > 0` seconds: the difference modulo `2^56`
    /// (Uniswap's own wrap), divided by `window` rounding toward negative infinity; `ok` false outside
    /// `[MIN_TICK, MAX_TICK]`. Never reverts for `int56` inputs. Example: `Δ = -497,384,100`, `window = 1,800` gives
    /// `-276,325`.
    /// @custom:spec SPEC-ORC-010
    function _meanOf(
        int256 c0,
        int256 c1,
        uint32 window
    ) internal pure returns (bool ok, int24 tick) {
        if (window == 0) return (false, 0);
        int256 delta;
        unchecked {
            // Cumulatives wrap at 56 bits by design; the difference is taken modulo 2^56, as Uniswap does.
            // forge-lint: disable-next-line(unsafe-typecast)
            delta = int256(int56(c1 - c0));
        }
        int256 w = int256(uint256(window));
        int256 mean = delta / w;
        if (delta < 0 && delta % w != 0) --mean;
        if (mean < ClPriceMath.MIN_TICK || mean > ClPriceMath.MAX_TICK) return (false, 0);
        // The mean lies in [MIN_TICK, MAX_TICK], inside int24.
        // forge-lint: disable-next-line(unsafe-typecast)
        (ok, tick) = (true, int24(mean));
    }

    /// @dev The head of an `(int56[2], uint160[2])` return: offsets 0x40 and 0xa0 and both lengths 2.
    function _observeShape(
        bytes memory ret
    ) private pure returns (bool) {
        (bool ok0, uint256 off0) = LPOracleCalls.wordAt(ret, 0);
        (bool ok1, uint256 off1) = LPOracleCalls.wordAt(ret, _W);
        (bool ok2, uint256 len0) = LPOracleCalls.wordAt(ret, 2 * _W);
        (bool ok5, uint256 len1) = LPOracleCalls.wordAt(ret, 5 * _W);
        return ok0 && ok1 && ok2 && ok5 && off0 == 2 * _W && off1 == 5 * _W && len0 == 2 && len1 == 2;
    }
}
