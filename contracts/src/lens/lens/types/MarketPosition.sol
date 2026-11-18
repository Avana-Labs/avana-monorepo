// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "../../../types/PriceState.sol";

/// @notice One collateral market of an account.
/// @dev `shortfall` are units seized on Aave and not yet reconciled; `rescueUnits` never support new debt.
struct MarketPosition {
    address vaultToken;
    uint256 reserveId;
    uint256 suppliedShares;
    uint256 suppliedAssets;
    bool collateralEnabled;
    uint256 credited;
    uint256 recordCount;
    uint256 shortfall;
    PriceState priceState;
    uint32 breakerReasons;
    uint256 rescueUnits;
}
