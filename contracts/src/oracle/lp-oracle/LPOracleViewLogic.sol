// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleConfig} from "../../types/OracleConfig.sol";
import {PriceState} from "../../types/PriceState.sol";
import {PriceStateView} from "../../types/PriceStateView.sol";
import {ILPOracleLogic} from "./ILPOracleLogic.sol";
import {LPOracleLogicBase} from "./LPOracleLogicBase.sol";
import {Evaluation} from "./LPOracleTypes.sol";
import {InitParams} from "./types/InitParams.sol";

/// @title LPOracleViewLogic
/// @notice The LPOracle's evaluation views, run by delegatecall from the implementation's view of the same selector
/// (2.10 Views and freshness exposure): the served price, the Chainlink-compatible round, the full report, the
/// valuation prices and the two age limits, all from one evaluation in the block.
/// @dev Writes no storage and makes only static calls. The served-price views evaluate without second sources, which
/// change none of their return values (`REQ-ORACLE-100`); `getPriceState` evaluates them. Called directly rather than
/// by delegatecall it evaluates its own empty storage, which reads as a failed market.
/// @custom:spec REQ-ORACLE-106, REQ-ORACLE-020, REQ-ORACLE-041, REQ-ORACLE-042, REQ-ORACLE-043, REQ-ORACLE-044, REQ-ORACLE-045, REQ-ORACLE-060, REQ-ORACLE-061
// Its `latestRoundData` is the LPOracle's Chainlink-compatible view, not a sequencer-uptime feed.
// forge-lint: disable-next-line(missing-inheritance)
abstract contract LPOracleViewLogic is LPOracleLogicBase {
    /// @notice Served price (`SPEC-ORC-017`).
    /// @custom:spec REQ-ORACLE-020, REQ-ORACLE-060, REQ-ORACLE-061, SPEC-ORC-017
    function latestAnswer() external view returns (int256 answer) {
        // served >= 1 and below 2^255 (SPEC-ORC-017).
        // forge-lint: disable-next-line(unsafe-typecast)
        answer = int256(_evaluate(false).served);
    }

    /// @notice Served price with its original source timestamp (`REQ-ORACLE-041`).
    /// @custom:spec REQ-ORACLE-041, REQ-ORACLE-021
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        Evaluation memory e = _evaluate(false);
        // served >= 1 and below 2^255 (SPEC-ORC-017).
        // forge-lint: disable-next-line(unsafe-typecast)
        answer = int256(e.served);
        (startedAt, updatedAt) = (e.servedUpdatedAt, e.servedUpdatedAt);
        roundId = uint80(e.servedUpdatedAt);
        answeredInRound = roundId;
    }

    /// @notice Full price-state report (`REQ-ORACLE-042`).
    /// @custom:spec REQ-ORACLE-042
    function getPriceState() external view returns (PriceStateView memory report) {
        report = _report(_evaluate(true));
    }

    /// @notice Valuation prices: the fresh vector, or the accepted one when failed or held by the quote-change cap.
    /// @custom:spec REQ-ORACLE-044, REQ-ORACLE-009, REQ-ORACLE-103
    function getTokenPrices()
        external
        view
        returns (uint256[] memory prices, uint64 servedUpdatedAt, PriceState state)
    {
        Evaluation memory e = _evaluate(false);
        (servedUpdatedAt, state) = (e.servedUpdatedAt, e.state);
        if (!e.failed && !e.quoteCapped) return (e.prices, servedUpdatedAt, state);
        uint128[] storage stored = _s().accepted.prices;
        prices = new uint256[](stored.length);
        for (uint256 i = 0; i < stored.length; ++i) {
            prices[i] = stored[i];
        }
    }

    /// @notice Borrow age limit of the served price (`SPEC-ORC-015`).
    /// @custom:spec REQ-ORACLE-043, SPEC-ORC-015
    function borrowPriceMaxAge() external view returns (uint32 age) {
        age = _evaluate(false).borrowMaxAge;
    }

    /// @notice Liquidation age limit of the served price (`SPEC-ORC-015`, `REQ-ORACLE-090`).
    /// @custom:spec REQ-ORACLE-043, REQ-ORACLE-090, SPEC-ORC-015
    function liquidationPriceMaxAge() external view returns (uint32 age) {
        age = _evaluate(false).liquidationMaxAge;
    }

    /// @inheritdoc ILPOracleLogic
    function poke() external pure override returns (PriceState) {
        revert NotDelegated();
    }

    /// @inheritdoc ILPOracleLogic
    function initializeMarket(
        InitParams calldata
    ) external pure override {
        revert NotDelegated();
    }

    /// @inheritdoc ILPOracleLogic
    function checkConfig(
        OracleConfig calldata
    ) external pure override returns (uint256) {
        revert NotDelegated();
    }
}
