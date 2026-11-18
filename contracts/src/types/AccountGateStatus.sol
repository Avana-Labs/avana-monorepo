// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DriftReason} from "./DriftReason.sol";
import {MarketGateStatus} from "./MarketGateStatus.sol";
import {PauseReason} from "./PauseReason.sol";
import {PauseState} from "./PauseState.sol";

/// @notice Every borrow-side gate outcome for one account on one CDP Spoke, returned without reverting.
/// @dev A reserve ID field holds `type(uint256).max` when no reserve fails (reserve 0 is valid).
struct AccountGateStatus {
    // True when `spoke` is an approved Avana CDP Spoke.
    bool spokeApproved;
    // Per-market outcomes for the collateral scope.
    MarketGateStatus[] markets;
    // First collateral reserve that maps to no Active or Offboarding market.
    uint256 unknownCollateralReserveId;
    // First debt reserve of the account that the MarketRegistry has not enabled for the Spoke.
    uint256 unapprovedDebtReserveId;
    // First debt reserve of the account paused on Aave.
    uint256 pausedDebtReserveId;
    // First debt reserve of the account on an unexpected price source or with a stale or non-Live DebtOracle.
    uint256 staleDebtReserveId;
    // First debt reserve of the account whose flash source and caller-funded path are both unavailable.
    uint256 haltedDebtReserveId;
    // Market of the first drift failure (0 for Spoke-wide and debt-reserve reasons).
    uint256 driftMarketId;
    DriftReason driftReason;
    // LPVaultSwap.activeKeeperCount() == 0 (no approved keeper that is not frozen).
    bool noApprovedKeeper;
    PauseState pauseState;
    // Current health factor, WAD.
    uint256 healthFactor;
    // hardHealthFloor(marketId) from the ParameterStore, WAD; 0 when off.
    uint256 hardHealthFloor;
    // True when every preBorrowCheck check that does not depend on the reserve borrowed passes now.
    bool borrowAllowed;
    // True when preWithdrawCheck would pass now, every held debt reserve's debt breaker included.
    bool withdrawWithDebtAllowed;
    // MarketRegistry pause reason (None unless Paused).
    PauseReason pauseReason;
    // Health factor with rescue units valued at zero, WAD.
    uint256 healthFactorExcludingRescue;
    // First debt reserve of the account whose debt breaker is tripped.
    uint256 breakerDebtReserveId;
    // Bitmap of tripped BreakerReasons of that debt reserve.
    uint32 debtBreakerReasons;
    bool statusUnavailable;
}
