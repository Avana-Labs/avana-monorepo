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
/// `liquidationThresholdBps` are both the reserve's latest collateral factor; headroom as `CapView`. The risk
/// configuration of REQ-LENS-057: `collateralRiskBps` (the reserve's `collateralRisk`, the risk premium of every account
/// of the market), `liquidationFeeBps` (latest dynamic configuration), the Spoke's liquidation configuration
/// (`targetHealthFactor` and `healthFactorForMaxBonus` WAD, `liquidationBonusFactorBps`), `hardHealthFloor` (WAD, 0 =
/// off), Avana's caps (USD 8 decimals: `marketUsdCap`, `topUpSliceUsd`, the Hub's `depositorUsdCap`, `tokenUsdCaps` per
/// pool token), the Hub's `addCap` of the vault token (whole units, `type(uint40).max` = none) and, per enabled debt
/// reserve of the Spoke (`debtReserveIds`), `borrowRatesRay = ⌈drawnRate × (10⁴ + collateralRiskBps) / 10⁴⌉`.
/// @custom:spec REQ-LENS-045, REQ-LENS-057, REQ-LENS-005
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
    // Risk configuration (REQ-LENS-057).
    uint256 collateralRiskBps;
    uint256 liquidationFeeBps;
    uint256 targetHealthFactor;
    uint256 healthFactorForMaxBonus;
    uint256 liquidationBonusFactorBps;
    uint256 hardHealthFloor;
    uint256 marketUsdCap;
    uint256 topUpSliceUsd;
    uint256 depositorUsdCap;
    uint256[] tokenUsdCaps;
    uint256 addCap;
    uint256[] debtReserveIds;
    uint256[] borrowRatesRay;
}
