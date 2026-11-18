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
/// @notice The LPOracle's evaluation views, run by delegatecall from the implementation.
/// @dev Writes no storage. Called directly, it reads its own empty storage as a failed market.
// Its `latestRoundData` is the LPOracle's Chainlink-compatible view, not a sequencer-uptime feed.
// forge-lint: disable-next-line(missing-inheritance)
abstract contract LPOracleViewLogic is LPOracleLogicBase {
    function latestAnswer() external view returns (int256 answer) {
        // served >= 1 and below 2^255.
        // forge-lint: disable-next-line(unsafe-typecast)
        answer = int256(_evaluate(false).served);
    }

    /// @notice Served price with its source timestamp.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        Evaluation memory e = _evaluate(false);
        // served >= 1 and below 2^255.
        // forge-lint: disable-next-line(unsafe-typecast)
        answer = int256(e.served);
        (startedAt, updatedAt) = (e.servedUpdatedAt, e.servedUpdatedAt);
        roundId = uint80(e.servedUpdatedAt);
        answeredInRound = roundId;
    }

    function getPriceState() external view returns (PriceStateView memory report) {
        report = _report(_evaluate(true));
    }

    /// @notice Valuation prices: the fresh vector, or the accepted one when failed or held by the quote-change cap.
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

    function borrowPriceMaxAge() external view returns (uint32 age) {
        age = _evaluate(false).borrowMaxAge;
    }

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
