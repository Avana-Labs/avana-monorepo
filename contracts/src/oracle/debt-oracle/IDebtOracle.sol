// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4PriceFeed} from "../../interfaces/external/aave/IAaveV4PriceFeed.sol";
import {PriceState} from "../../types/PriceState.sol";
import {IDebtOracleErrors} from "./IDebtOracleErrors.sol";
import {IDebtOracleEvents} from "./IDebtOracleEvents.sol";
import {DebtOracleInitParams} from "./types/DebtOracleInitParams.sol";
import {DebtPriceView} from "./types/DebtPriceView.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title IDebtOracle
/// @notice Price feed for one debt asset with a market price: the USD price of one whole token, with 8 decimals.
/// @dev UUPS proxy; only the timelock can upgrade it.
interface IDebtOracle is IAaveV4PriceFeed, IAccessControl, IDebtOracleEvents, IDebtOracleErrors {
    /// @notice Initializes the feed and seeds the accepted price.
    /// @dev Reverts `NotDebtAsset` unless the asset is listed with readable routes, `NotLive` unless Live.
    function initialize(
        DebtOracleInitParams calldata params
    ) external;

    /// @notice Served debt price, 8 decimals, always >= 1.
    /// @dev Never below the accepted price unless Live. Never reverts except `InsufficientGas`.
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
    function getPriceState() external view returns (DebtPriceView memory report);

    /// @notice Last Live price `poke()` stored, with its source timestamp.
    function lastAcceptedPrice() external view returns (uint256 price8, uint64 updatedAt);

    /// @notice Borrow age limit of the served price, in seconds; 0 when the accepted price is served.
    function borrowPriceMaxAge() external view returns (uint32 age);

    /// @notice Liquidation age limit of the served price, in seconds; 0 when the accepted price is served.
    function liquidationPriceMaxAge() external view returns (uint32 age);

    /// @notice Evaluates the asset and stores the accepted price, timers, grace latch and route version.
    /// @dev Permissionless. Reverts `InsufficientGas` at entry below `pokeMinGas`.
    function poke() external returns (PriceState state);

    /// @notice Changes `pokeMinGas`.
    /// @dev Only `APPLICATION_ADMIN`.
    function setPokeMinGas(
        uint32 value
    ) external;

    /// @notice Minimum gas for `poke()` and after every caught failure.
    function pokeMinGas() external view returns (uint32 value);

    /// @notice The debt asset this feed prices.
    function ASSET() external view returns (address asset);

    /// @notice MarketRegistry address.
    function MARKET_REGISTRY() external view returns (address registry);

    /// @notice ParameterStore address.
    function PARAMETER_STORE() external view returns (address store);

    /// @notice The timelock, the only account that may hold `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN`.
    function TIMELOCK() external view returns (address timelock);
}
