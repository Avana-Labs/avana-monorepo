// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DriftReason} from "./DriftReason.sol";
import {MarketGateStatus} from "./MarketGateStatus.sol";
import {PauseReason} from "./PauseReason.sol";
import {PauseState} from "./PauseState.sol";

/// @notice Every borrow-side gate outcome for one account on one CDP Spoke, returned without reverting.
/// @dev Evaluated by `RiskModule.getAccountGateStatus` with the same code paths as the pre-checks, on stored LPOracle
/// state. A reserve ID field holds `type(uint256).max` (no reserve) when no reserve fails that check, because reserve 0
/// is a valid identifier. `borrowAllowed` and `withdrawWithDebtAllowed` are the RiskModule's own checks; the pause state
/// of the market's Hub is reported in `pauseState` and `pauseReason` only and never changes another field (PROP-066).
/// When the status cannot be computed, `statusUnavailable` is true, every reserve ID field is `type(uint256).max`, both
/// "would pass" flags are false and every other field is zero, false or empty; the app then shows "Risk status
/// unavailable. Refresh and try again." and reads no other field.
/// @custom:spec REQ-ADAPTER-038, REQ-RISK-060, REQ-RISK-065, REQ-RISK-068, REQ-RISK-071, Q-241, Q-248, Q-252, Q-253
struct AccountGateStatus {
    // True when `spoke` is an approved Avana CDP Spoke.
    bool spokeApproved;
    // Per-market outcomes for the collateral scope (REQ-ADAPTER-012).
    MarketGateStatus[] markets;
    // First collateral reserve that maps to no Active or Offboarding market.
    uint256 unknownCollateralReserveId;
    // First debt reserve of the account that the MarketRegistry has not enabled for the Spoke.
    uint256 unapprovedDebtReserveId;
    // First debt reserve of the account paused on Aave.
    uint256 pausedDebtReserveId;
    // First debt reserve of the account on an unexpected price source, or whose DebtOracle is not Live or is older than
    // its borrowPriceMaxAge().
    uint256 staleDebtReserveId;
    // First debt reserve of the account whose flash source and caller-funded path are both unavailable (flash source
    // replaced or paused for its asset).
    uint256 haltedDebtReserveId;
    // Market of the first drift failure (0 for Spoke-wide and debt-reserve reasons).
    uint256 driftMarketId;
    // First drift reason, or None.
    DriftReason driftReason;
    // LPVaultSwap.activeKeeperCount() == 0 (no approved keeper that is not frozen).
    bool noApprovedKeeper;
    // MarketRegistry application pause state.
    PauseState pauseState;
    // Current health factor, WAD.
    uint256 healthFactor;
    // hardHealthFloor(marketId) from the ParameterStore, WAD; 0 when off (the default, Q-398).
    uint256 hardHealthFloor;
    // True when every check of preBorrowCheck that does not depend on the reserve borrowed passes now; no debt breaker,
    // credit line or coverage is read, because preBorrowCheck reads them for the borrowed reserve only (REQ-ADAPTER-038).
    bool borrowAllowed;
    // True when preWithdrawCheck would pass now, every held debt reserve's debt breaker included.
    bool withdrawWithDebtAllowed;
    // MarketRegistry pause reason (None unless Paused).
    PauseReason pauseReason;
    // Health factor with rescue units valued at zero (SPEC-CF-005), WAD.
    uint256 healthFactorExcludingRescue;
    // First debt reserve of the account whose debt breaker is tripped.
    uint256 breakerDebtReserveId;
    // Bitmap of tripped BreakerReasons of that debt reserve.
    uint32 debtBreakerReasons;
    // True when the status could not be computed (the fallback described above).
    bool statusUnavailable;
}
