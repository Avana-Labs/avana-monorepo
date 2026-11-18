// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../amm/concentrated-liquidity/ClPriceMath.sol";
import {IUniswapV3Pool} from "../../interfaces/external/uniswap/IUniswapV3Pool.sol";
import {OracleConfig, SecondSource, SecondSourceKind} from "../../types/OracleTypes.sol";
import {ShapeKind} from "../../types/PositionTypes.sol";
import {LPOracleCalls} from "./LPOracleCalls.sol";
import {LPOracleStorage} from "./LPOracleStorage.sol";

/// @title LPOracleCLPool
/// @notice Market storage and pool reads of the concentrated-liquidity pricing module.
/// @dev A malformed pool answer is a failed read, never a revert.
abstract contract LPOracleCLPool is LPOracleStorage {
    /// @notice The market's pool, range, the range's sqrt ratios and the pool's unit exponent.
    /// @custom:storage-location erc7201:avana.storage.LPOracleCL
    struct ClLayout {
        address pool;
        int24 tickLower;
        int24 tickUpper;
        int24 tickSpacing;
        uint160 sqrtLower;
        uint160 sqrtUpper;
        // Unit exponent `k`: one vault-token unit is `10^k` liquidity.
        uint8 unitExp;
        // Uniswap v4 `PoolId` (then `pool` is the reference v3 pool); zero for a pool keyed by address.
        bytes32 poolId;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("avana.storage.LPOracleCL")) - 1)) & ~bytes32(uint256(0xff)).
    bytes32 private constant _CL_SLOT = 0xb7c40d03a80aa05aa5c63763d6d3607d29246f15ca457871c1bef2104cb45600;

    uint256 private constant _W = 32;
    uint256 private constant _OBSERVE_LENGTH = 8 * _W;

    /// @dev Number of words `slot0()` returns: 7 on Uniswap v3, 6 on Aerodrome Slipstream.
    uint8 internal immutable _SLOT0_WORDS;

    struct ClListingInputs {
        uint32 twapWindow;
        uint16 consistencyToleranceBps;
        uint16 twapMinObservations;
        uint8 pairs;
        SecondSourceKind[2] kinds;
        bytes32[2] poolRefs;
    }

    /// @param slot0Words 7 for Uniswap v3, 6 for Aerodrome Slipstream.
    constructor(
        uint8 slot0Words
    ) {
        if (slot0Words != 6 && slot0Words != 7) revert MarketMismatch(0);
        _SLOT0_WORDS = slot0Words;
    }

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

    /// @notice Words of the pool's `slot0()` return: 7 (Uniswap v3) or 6 (Slipstream).
    function SLOT0_WORDS() external view returns (uint8 words) {
        words = _SLOT0_WORDS;
    }

    function _cl() internal pure returns (ClLayout storage c) {
        // ERC-7201 namespaced storage: the slot is a compile-time constant.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            c.slot := _CL_SLOT
        }
    }

    /// @dev The observation cardinality (word 3) and `unlocked` (the last word) from `slot0()`.
    function _slot0(
        address pool
    ) internal view returns (bool ok, uint16 cardinality, bool unlocked) {
        uint256 length = uint256(_SLOT0_WORDS) * _W;
        bytes memory ret;
        (ok, ret) = LPOracleCalls.staticRead(pool, POOL_CALL_GAS, abi.encodeCall(IUniswapV3Pool.slot0, ()), length + 1);
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

    function _poolAddress(
        address pool,
        bytes memory data,
        uint256 callGas
    ) internal view returns (bool ok, address value) {
        bytes memory ret;
        (ok, ret) = LPOracleCalls.staticRead(pool, callGas, data, _W + 1);
        uint256 word = 0;
        if (ok && ret.length == _W) (ok, word) = LPOracleCalls.uintAt(ret, 0, type(uint160).max);
        else ok = false;
        // `uintAt` bounds `word` by type(uint160).max.
        // forge-lint: disable-next-line(unsafe-typecast)
        value = address(uint160(word));
    }

    function _tickSpacing(
        address pool
    ) internal view returns (bool ok, int24 spacing) {
        bytes memory ret;
        (ok, ret) =
            LPOracleCalls.staticRead(pool, CONFIG_CALL_GAS, abi.encodeCall(IUniswapV3Pool.tickSpacing, ()), _W + 1);
        int256 value = 0;
        if (ok && ret.length == _W) (ok, value) = LPOracleCalls.intAt(ret, 0, 24);
        else ok = false;
        // intAt checked that the word is a sign-extended int24.
        // forge-lint: disable-next-line(unsafe-typecast)
        spacing = int24(value);
    }

    /// @dev Mean tick of `pool` over `window` seconds, as Uniswap's `OracleLibrary.consult`.
    function _meanTick(
        address pool,
        uint32 window
    ) internal view returns (bool ok, int24 tick) {
        if (window == 0) return (false, 0);
        uint32[] memory ago = new uint32[](2);
        ago[0] = window;
        bytes memory ret;
        (ok, ret) = LPOracleCalls.staticRead(
            pool, OBSERVE_CALL_GAS, abi.encodeCall(IUniswapV3Pool.observe, (ago)), _OBSERVE_LENGTH + 1
        );
        if (!ok || ret.length != _OBSERVE_LENGTH || !_observeShape(ret)) return (false, 0);
        int256 c0 = 0;
        int256 c1 = 0;
        (ok, c0) = LPOracleCalls.intAt(ret, 3 * _W, 56);
        if (ok) (ok, c1) = LPOracleCalls.intAt(ret, 4 * _W, 56);
        if (!ok) return (false, 0);
        (ok, tick) = _meanOf(c0, c1, window);
    }

    /// @dev Mean tick of two cumulatives, rounded toward negative infinity; `ok` false outside the tick range.
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

    function _observeShape(
        bytes memory ret
    ) private pure returns (bool) {
        (bool ok0, uint256 off0) = LPOracleCalls.wordAt(ret, 0);
        (bool ok1, uint256 off1) = LPOracleCalls.wordAt(ret, _W);
        (bool ok2, uint256 len0) = LPOracleCalls.wordAt(ret, 2 * _W);
        (bool ok5, uint256 len1) = LPOracleCalls.wordAt(ret, 5 * _W);
        return ok0 && ok1 && ok2 && ok5 && off0 == 2 * _W && off1 == 5 * _W && len0 == 2 && len1 == 2;
    }

    /// @dev The record names this module's pool (or v4 `PoolId`), a `TickRange` shape and the stored range.
    function _isOwnMarket(
        uint256 poolWord,
        uint256 poolIdWord,
        uint256 kindWord,
        uint256 tickLowerWord,
        uint256 tickUpperWord
    ) internal view override returns (bool own) {
        ClLayout storage c = _cl();
        // An ABI-encoded int24 is its sign extension to 256 bits, the two's-complement word of the int256.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 lower = uint256(int256(c.tickLower));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 upper = uint256(int256(c.tickUpper));
        bytes32 id = c.poolId;
        bool pool = id == bytes32(0)
            ? poolWord == uint160(c.pool) && poolIdWord == 0
            : poolWord == 0 && poolIdWord == uint256(id);
        own = pool && kindWord == uint256(ShapeKind.TickRange) && tickLowerWord == lower && tickUpperWord == upper;
    }
}
