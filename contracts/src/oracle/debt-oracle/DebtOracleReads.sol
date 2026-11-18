// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAggregatorProxy} from "../../interfaces/external/chainlink/IAggregatorProxy.sol";
import {IAggregatorV3} from "../../interfaces/external/chainlink/IAggregatorV3.sol";
import {IParameterStoreViews} from "../../policy/parameter-store/IParameterStoreViews.sol";
import {LPPriceMath} from "../lp-oracle/LPPriceMath.sol";
import {DebtOracleStorage} from "./DebtOracleStorage.sol";
import {IDebtOracleErrors} from "./IDebtOracleErrors.sol";
import {LegRead, ReadStatus} from "./types/DebtEvaluation.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title DebtOracleReads
/// @notice Gas-guarded static reads of the DebtOracle and their decoding into fixed-width values.
/// @dev A read reverts `InsufficientGas` unless it can forward its full gas; a malformed word is a failed decode.
abstract contract DebtOracleReads is DebtOracleStorage {
    /// @dev One gas-guarded static call; copies at most `maxWords` whole words of the return data.
    function _call(
        address target,
        uint256 callGas,
        bytes memory data,
        uint256 maxWords
    ) internal view returns (bool ok, uint256 size, uint256[] memory words) {
        uint256 required = LPPriceMath.gasForCall(callGas);
        // The gas guard must revert wherever the read is made, also inside the bounded loops over legs and routes.
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (gasleft() < required) revert IDebtOracleErrors.InsufficientGas(gasleft(), required);
        words = new uint256[](maxWords);
        // Bounded copy of at most `maxWords` words; the array length is only ever lowered.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            ok := staticcall(callGas, target, add(data, 32), mload(data), 0, 0)
            size := returndatasize()
            let len := and(size, not(31))
            let cap := shl(5, maxWords)
            if gt(len, cap) { len := cap }
            returndatacopy(add(words, 32), 0, len)
            mstore(words, shr(5, len))
        }
    }

    function _callOf(
        address target,
        bytes4 selector,
        address arg,
        uint256 maxWords
    ) internal view returns (bool ok, uint256 size, uint256[] memory words) {
        return _call(target, CONFIG_CALL_GAS, abi.encodePacked(selector, uint256(uint160(arg))), maxWords);
    }

    /// @dev One configuration word of at most `maxValue` from a getter with no argument.
    function _readWord(
        address target,
        bytes4 selector,
        uint256 maxValue
    ) internal view returns (bool ok, uint256 value) {
        (bool s,, uint256[] memory w) = _call(target, CONFIG_CALL_GAS, abi.encodePacked(selector), 1);
        return _boundedWord(s, w, maxValue);
    }

    function _readWordOf(
        address target,
        bytes4 selector,
        address arg,
        uint256 maxValue
    ) internal view returns (bool ok, uint256 value) {
        (bool s,, uint256[] memory w) = _callOf(target, selector, arg, 1);
        return _boundedWord(s, w, maxValue);
    }

    function _boundedWord(
        bool called,
        uint256[] memory w,
        uint256 maxValue
    ) private pure returns (bool ok, uint256 value) {
        if (!called || w.length < 1 || w[0] > maxValue) return (false, 0);
        return (true, w[0]);
    }

    /// @dev A feed's pinned decimals, bounds and age limits from `ParameterStore.getFeed`; `decimals == 0` means none.
    function _readFeedDef(
        address store,
        LegRead memory leg
    ) internal view returns (bool ok) {
        (bool s,, uint256[] memory w) = _callOf(store, IParameterStoreViews.getFeed.selector, leg.feed, 10);
        if (!s || w.length < 10 || w[0] == 0 || w[0] > type(uint8).max) return false;
        if (w[3] > type(uint32).max || w[4] > type(uint32).max || w[5] > type(uint32).max) return false;
        if (w[6] > type(uint16).max || w[7] > type(uint16).max) return false;
        if (w[8] > type(uint32).max || w[9] > type(uint32).max) return false;
        leg.pinnedDecimals = SafeCast.toUint8(w[0]);
        leg.minAnswer = _signed(w[1]);
        leg.maxAnswer = _signed(w[2]);
        leg.maxAge = LPPriceMath.feedMaxAge(SafeCast.toUint32(w[3]), SafeCast.toUint32(w[4]));
        leg.borrowMaxAge = SafeCast.toUint32(w[8]);
        leg.liquidationMaxAge = SafeCast.toUint32(w[9]);
        return true;
    }

    function _readDecimals(
        address feed
    ) internal view returns (bool ok, uint8 value) {
        (bool s,, uint256[] memory w) = _call(feed, FEED_CALL_GAS, abi.encodeCall(IAggregatorV3.decimals, ()), 1);
        if (!s || w.length < 1 || w[0] > type(uint8).max) return (false, 0);
        return (true, SafeCast.toUint8(w[0]));
    }

    /// @dev A `latestRoundData()` or `getRoundData()` read; `size` is the full `returndatasize()`.
    function _readRound(
        address feed,
        bytes memory data
    )
        internal
        view
        returns (bool ok, uint80 roundId, int256 answer, uint256 startedAt, uint64 updatedAt, uint256 size)
    {
        uint256[] memory w;
        (ok, size, w) = _call(feed, FEED_CALL_GAS, data, 5);
        if (!ok || w.length < 5 || w[0] > type(uint80).max || w[4] > type(uint80).max || w[3] > type(uint64).max) {
            return (false, 0, 0, 0, 0, size);
        }
        return (true, SafeCast.toUint80(w[0]), _signed(w[1]), w[2], SafeCast.toUint64(w[3]), size);
    }

    function _readLatest(
        address feed
    )
        internal
        view
        returns (bool ok, uint80 roundId, int256 answer, uint256 startedAt, uint64 updatedAt, uint256 size)
    {
        return _readRound(feed, abi.encodeCall(IAggregatorV3.latestRoundData, ()));
    }

    function _readPhaseAggregator(
        address proxy,
        uint16 phaseId
    ) internal view returns (bool ok, address aggregator) {
        (bool s,, uint256[] memory w) =
            _call(proxy, FEED_CALL_GAS, abi.encodeCall(IAggregatorProxy.phaseAggregators, (phaseId)), 1);
        if (!s || w.length < 1 || w[0] > type(uint160).max) return (false, address(0));
        return (true, address(SafeCast.toUint160(w[0])));
    }

    /// @dev Reads and classifies one leg; `oneLeg` also requires a normalised answer of at least 1.
    function _readLeg(
        LegRead memory leg,
        bool oneLeg
    ) internal view {
        (bool okDec, uint8 dec) = _readDecimals(leg.feed);
        (bool okRound, uint80 roundId, int256 answer,, uint64 updatedAt,) = _readLatest(leg.feed);
        if (!okDec || !okRound) {
            leg.status = ReadStatus.Error;
            return;
        }
        leg.roundId = roundId;
        leg.answer = answer;
        leg.updatedAt = updatedAt;
        bool invalid = dec != leg.pinnedDecimals || answer <= leg.minAnswer || answer >= leg.maxAnswer || updatedAt == 0
            || updatedAt > block.timestamp || (oneLeg && LPPriceMath.normalizeAnswer(answer, dec) == 0);
        if (invalid) leg.status = ReadStatus.Invalid;
        else if (block.timestamp - updatedAt > leg.maxAge) leg.status = ReadStatus.Stale;
        else leg.status = ReadStatus.Valid;
    }

    function _signed(
        uint256 word
    ) internal pure returns (int256 value) {
        // forge-lint: disable-next-line(unsafe-typecast)
        value = int256(word);
    }
}
