// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketStatus} from "../../../policy/market-registry/types/MarketStatus.sol";
import {PauseState} from "../../../types/PauseState.sol";
import {PriceState} from "../../../types/PriceState.sol";

/// @notice One market for the app's market list, with its risk configuration.
/// @dev Prices and caps USD 8 decimals; health factors WAD; rates RAY per year.
struct MarketView {
    uint256 blockNumber;
    uint256 timestamp;
    uint256 marketId;
    uint64 chainId;
    MarketStatus status;
    address pool;
    bytes32 poolId;
    address[] tokens;
    uint8[] tokenDecimals;
    uint24 feeTier;
    int24 tickLower;
    int24 tickUpper;
    uint32 integrationId;
    bytes32 ammProtocol;
    address vaultToken;
    string name;
    string symbol;
    address lpOracle;
    address hub;
    address spoke;
    uint256 reserveId;
    uint256 hubAssetId;
    uint256 acceptedPrice;
    PriceState priceState;
    uint256 suppliedUnits;
    uint256 suppliedUsd;
    uint256 collateralFactorBps;
    uint256 liquidationThresholdBps;
    uint256 maxLiquidationBonusBps;
    uint256 marketHeadroomUsd;
    uint256 sliceHeadroomUsd;
    uint256 addHeadroom;
    PauseState pauseState;
    uint32 breakerReasons;
    uint256 collateralRiskBps;
    uint256 liquidationFeeBps;
    uint256 targetHealthFactor;
    uint256 healthFactorForMaxBonus;
    uint256 liquidationBonusFactorBps;
    uint256 hardHealthFloor;
    uint256 marketUsdCap;
    uint256 topUpSliceUsd;
    uint256[] tokenUsdCaps;
    uint256 addCap;
    uint256[] debtReserveIds;
    uint256[] borrowRatesRay;
}
