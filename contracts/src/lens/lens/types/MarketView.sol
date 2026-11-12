// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketStatus} from "../../../policy/market-registry/types/MarketStatus.sol";
import {PauseState} from "../../../types/PauseState.sol";
import {PriceState} from "../../../types/PriceState.sol";

/// @notice One market for the app's market list (REQ-LENS-045).
/// @dev Identity from the MarketRegistry record, the AMM integration and the vault token; `acceptedPrice` USD 8
/// decimals per whole vault token; `suppliedUnits` the CDP Spoke's added assets of the vault-token asset on the Hub
/// and `suppliedUsd` their value at the accepted price, rounded down; `collateralFactorBps` and
/// `liquidationThresholdBps` are both the reserve's latest collateral factor; headroom as `CapView`.
/// @custom:spec REQ-LENS-045, REQ-LENS-005
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
}
