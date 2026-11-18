// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "./PriceState.sol";

/// @notice Borrow-side gate outcome for one collateral market of an account.
struct MarketGateStatus {
    // MarketRegistry market identifier (0 when the reserve maps to no market).
    uint256 marketId;
    // CDP Spoke reserve identifier of the market's vault token.
    uint256 reserveId;
    PriceState priceState;
    // Age of the oldest price input, seconds.
    uint256 oldestFeedAge;
    // True when some input is older than its borrowPriceMaxAge.
    bool feedTooOld;
    bool offboarding;
    // The market's vault-token reserve is paused on the CDP Spoke.
    bool aaveReservePaused;
    // The market's vault-token reserve is frozen on the CDP Spoke.
    bool aaveReserveFrozen;
    // HUB.getAddedAssets == HUB.getAddedShares for the vault-token asset.
    bool hubSharesEqualAssets;
    // Some pool token other than the debt asset has no usable swap route.
    bool noSettlementPath;
    bool liquidationHalted;
    // Bitmap of tripped BreakerReasons of the market (condition and latched).
    uint32 breakerReasons;
    // End of the market's latched breaker; 0 or past when none.
    uint64 breakerLatchedUntil;
}
