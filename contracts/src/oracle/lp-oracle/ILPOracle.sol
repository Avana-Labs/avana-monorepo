// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4PriceFeed} from "../../interfaces/external/aave/IAaveV4PriceFeed.sol";
import {OracleConfig} from "../../types/OracleConfig.sol";
import {PriceState} from "../../types/PriceState.sol";
import {PriceStateView} from "../../types/PriceStateView.sol";
import {ILPOracleErrors} from "./ILPOracleErrors.sol";
import {ILPOracleEvents} from "./ILPOracleEvents.sol";
import {InitParams} from "./types/InitParams.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title ILPOracle
/// @notice Price feed for one Avana market: the USD value of one whole vault token, with 8 decimals.
/// @dev UUPS proxy; only the timelock can upgrade it.
interface ILPOracle is IAaveV4PriceFeed, IAccessControl, ILPOracleEvents, ILPOracleErrors {
    /// @notice Initializes the feed, runs the listing checks and seeds the accepted price.
    /// @dev Reverts unless the config passes `checkConfig` and the evaluation is Live.
    function initialize(
        InitParams calldata params
    ) external;

    /// @notice Served price: USD value of one whole vault token, 8 decimals, always >= 1.
    /// @dev Never reverts except `InsufficientGas`.
    function latestAnswer() external view override returns (int256 answer);

    /// @notice Decimals of the served price; always 8.
    function decimals() external view override returns (uint8);

    /// @notice Fixed description stored at `initialize`.
    function description() external view override returns (string memory);

    /// @notice Chainlink-compatible view of the served price.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice Full price-state report, computed by the same code as `latestAnswer()`.
    /// @dev Never reverts except `InsufficientGas`.
    function getPriceState() external view returns (PriceStateView memory report);

    /// @notice Capped valuation price of each token, for LPVaultSwap's minimum outputs.
    /// @return prices Valuation price of each token in pool order, 8 decimals.
    function getTokenPrices() external view returns (uint256[] memory prices, uint64 servedUpdatedAt, PriceState state);

    /// @notice Borrow age limit of the served price, in seconds.
    /// @dev 0 when the market is failed or the config read fails, so age checks fail closed.
    function borrowPriceMaxAge() external view returns (uint32 age);

    /// @notice Liquidation age limit of the served price, in seconds.
    /// @dev 0 when the market is failed or the config read fails, so age checks fail closed.
    function liquidationPriceMaxAge() external view returns (uint32 age);

    /// @notice Evaluates the market and stores the accepted price, timers, grace latch and checkpoint.
    /// @dev Permissionless. Reverts `InsufficientGas` at entry below `pokeMinGas`.
    function poke() external returns (PriceState state);

    /// @notice Last Live price `poke()` stored, with its source timestamp.
    function lastAcceptedPrice() external view returns (uint256 price8, uint64 updatedAt);

    /// @notice Hourly checkpoint of the accepted price, read by the RiskModule's price-drop breaker.
    function priceCheckpoint() external view returns (uint256 price8, uint64 at);

    /// @notice Runs the on-chain listing and configuration checks against a configuration.
    /// @return failedChecks Bitmap of failed checks; 0 means every check passes.
    function checkConfig(
        OracleConfig calldata config
    ) external view returns (uint256 failedChecks);

    /// @notice Changes `pokeMinGas`.
    /// @dev Only `APPLICATION_ADMIN`.
    function setPokeMinGas(
        uint32 value
    ) external;

    /// @notice Minimum gas for `poke()` and after every caught failure.
    function pokeMinGas() external view returns (uint32 value);

    /// @notice The stored token-decimals check result; while `invalid`, every evaluation is failed.
    /// @return invalid The last `poke()` found a token's decimals changed or unreadable.
    /// @return verifiedAt Block timestamp of the last successful verification.
    function decimalsStatus() external view returns (bool invalid, uint64 verifiedAt);

    /// @notice MarketRegistry identifier of the market this feed prices.
    function marketId() external view returns (uint256 id);

    /// @notice The market's AMM integration (LPVault).
    function integration() external view returns (address amm);

    /// @notice The market's tokens in pool order.
    function tokens() external view returns (address[] memory list);

    /// @notice ParameterStore address read on every evaluation.
    function parameterStore() external view returns (address store);

    /// @notice MarketRegistry address.
    function marketRegistry() external view returns (address registry);

    /// @notice Valuation ceiling for every USD-pegged stable leg, 8 decimals.
    function stableCeilingUsd() external view returns (uint256 value);

    /// @notice The timelock, the only account that may hold `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN`.
    function TIMELOCK() external view returns (address timelock);
}
