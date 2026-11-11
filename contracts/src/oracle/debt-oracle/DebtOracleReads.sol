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
/// @dev Every external read follows `SPEC-ORC-023`: immediately before it, `gasleft()` must be at least
/// `ceil(64 * G / 63) + POST_CALL_GAS`, otherwise the call reverts `InsufficientGas`, so the read receives exactly its
/// explicit gas `G` whatever the transaction's gas limit; a read that then fails is the source's own failure. The return
/// data is copied up to the ABI length the caller names and never beyond (`REQ-ORACLE-001`), so a source that returns
/// a huge buffer cannot charge the oracle for copying it. Words are decoded by hand: a word that does not fit its ABI
/// type is a failed decode, never a revert, because a revert in a view would break `REQ-ORACLE-061`.
/// @custom:spec SPEC-ORC-023, REQ-ORACLE-001, REQ-ORACLE-039, REQ-ORACLE-061, REQ-ORACLE-098, REQ-ORACLE-102
abstract contract DebtOracleReads is DebtOracleStorage {
    /// @dev One gas-guarded static call; copies at most `maxWords` whole words of the return data.
    /// @return ok The call did not revert.
    /// @return size Full `returndatasize()`.
    /// @return words The first `min(size / 32, maxWords)` words.
    /// @custom:spec SPEC-ORC-023, REQ-ORACLE-001, REQ-ORACLE-102
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
        // A static call that copies no return data, then a bounded copy of at most `maxWords` words into the array
        // allocated above; the array length is lowered to the words copied, never raised.
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

    /// @dev One configuration word of at most `maxValue` from a registry or store getter with a single return value.
    /// @custom:spec SPEC-ORC-023, REQ-ORACLE-017
    function _readWord(
        address target,
        bytes memory data,
        uint256 maxValue
    ) internal view returns (bool ok, uint256 value) {
        (bool s,, uint256[] memory w) = _call(target, CONFIG_CALL_GAS, data, 1);
        if (!s || w.length < 1 || w[0] > maxValue) return (false, 0);
        return (true, w[0]);
    }

    /// @dev Pinned decimals, bounds and age limits of a feed from `ParameterStore.getFeed` (10 static words). A record
    /// with `decimals == 0` is no feed definition.
    /// @custom:spec REQ-ORACLE-094, REQ-ORACLE-017, SPEC-ORC-019
    function _readFeedDef(
        address store,
        LegRead memory leg
    ) internal view returns (bool ok) {
        (bool s,, uint256[] memory w) =
            _call(store, CONFIG_CALL_GAS, abi.encodeCall(IParameterStoreViews.getFeed, (leg.feed)), 10);
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

    /// @dev `decimals()` of an aggregator (one word, at most 255).
    /// @custom:spec REQ-ORACLE-001
    function _readDecimals(
        address feed
    ) internal view returns (bool ok, uint8 value) {
        (bool s,, uint256[] memory w) = _call(feed, FEED_CALL_GAS, abi.encodeCall(IAggregatorV3.decimals, ()), 1);
        if (!s || w.length < 1 || w[0] > type(uint8).max) return (false, 0);
        return (true, SafeCast.toUint8(w[0]));
    }

    /// @dev A `latestRoundData()` or `getRoundData()` return (five words): round identifiers within `uint80`, an
    /// `updatedAt` below `2^64`; `startedAt` is returned unchecked.
    /// @custom:spec REQ-ORACLE-001, SPEC-ORC-014
    function _readRound(
        address feed,
        bytes memory data
    ) internal view returns (bool ok, uint80 roundId, int256 answer, uint256 startedAt, uint64 updatedAt) {
        (bool s,, uint256[] memory w) = _call(feed, FEED_CALL_GAS, data, 5);
        if (!s || w.length < 5 || w[0] > type(uint80).max || w[4] > type(uint80).max || w[3] > type(uint64).max) {
            return (false, 0, 0, 0, 0);
        }
        return (true, SafeCast.toUint80(w[0]), _signed(w[1]), w[2], SafeCast.toUint64(w[3]));
    }

    /// @dev `latestRoundData()` of a feed.
    function _readLatest(
        address feed
    ) internal view returns (bool ok, uint80 roundId, int256 answer, uint256 startedAt, uint64 updatedAt) {
        return _readRound(feed, abi.encodeCall(IAggregatorV3.latestRoundData, ()));
    }

    /// @dev `phaseAggregators(phaseId)` of a Chainlink proxy (one address word).
    /// @custom:spec REQ-ORACLE-089
    function _readPhaseAggregator(
        address proxy,
        uint16 phaseId
    ) internal view returns (bool ok, address aggregator) {
        (bool s,, uint256[] memory w) =
            _call(proxy, FEED_CALL_GAS, abi.encodeCall(IAggregatorProxy.phaseAggregators, (phaseId)), 1);
        if (!s || w.length < 1 || w[0] > type(uint160).max) return (false, address(0));
        return (true, address(SafeCast.toUint160(w[0])));
    }

    /// @dev Reads and classifies one leg under `REQ-ORACLE-002` and `REQ-ORACLE-003`; `leg` already holds its feed
    /// record. `oneLeg` adds the condition that the normalised answer is at least 1.
    /// @custom:spec REQ-ORACLE-001, REQ-ORACLE-002, REQ-ORACLE-003, SPEC-ORC-001, SPEC-ORC-019
    function _readLeg(
        LegRead memory leg,
        bool oneLeg
    ) internal view {
        (bool okDec, uint8 dec) = _readDecimals(leg.feed);
        (bool okRound, uint80 roundId, int256 answer,, uint64 updatedAt) = _readLatest(leg.feed);
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

    /// @dev Reinterprets an ABI word as the signed `int256` it encodes.
    function _signed(
        uint256 word
    ) internal pure returns (int256 value) {
        // forge-lint: disable-next-line(unsafe-typecast)
        value = int256(word);
    }
}
