// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "../../../types/PriceState.sol";

/// @notice One collateral market of an account.
/// @dev `suppliedShares` and `suppliedAssets` are vault-token units on the Spoke; `credited` is
/// `Collateralization.getAccountCredited`; `recordCount` is `Collateralization.getOpenRecordCount` (including zero-credit records);
/// `shortfall = max(0, credited - suppliedShares)` are units seized on Aave and not yet reconciled by Collateralization; `priceState`
/// is the market state of `getPriceState`; `breakerReasons` is `RiskModule.getBreakerStatus(marketId)` (condition and
/// latched); `rescueUnits` is `Collateralization.getAccountRescueUnits(proxy, vaultToken)`, units that never support new
/// debt.
/// @custom:spec REQ-LENS-009, REQ-LENS-037, Q-241, Q-253
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
