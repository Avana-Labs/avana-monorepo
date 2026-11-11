// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DriftReason} from "./DriftReason.sol";
import {MarketGateStatus} from "./MarketGateStatus.sol";
import {PauseReason} from "./PauseReason.sol";
import {PauseState} from "./PauseState.sol";

/// @notice Every borrow-side gate outcome for one account on one CDP Spoke, returned without reverting.
/// @dev Evaluated by `RiskModule.getAccountGateStatus` with the same code paths as the pre-checks, on stored LPOracle
/// state. A reserve ID field holds `type(uint256).max` when no reserve fails that check.
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
    // True when a borrow would pass the pause gate and preBorrowCheck now.
    bool borrowAllowed;
    // True when a withdraw-with-debt would pass the pause gate and preWithdrawCheck now for every collateral reserve.
    bool withdrawWithDebtAllowed;
    // MarketRegistry pause reason (None unless Paused).
    PauseReason pauseReason;
    // Health factor with rescue units valued at zero (SPEC-CF-005), WAD.
    uint256 healthFactorExcludingRescue;
    // First debt reserve of the account whose debt breaker is tripped.
    uint256 breakerDebtReserveId;
    // Bitmap of tripped BreakerReasons of that debt reserve.
    uint32 debtBreakerReasons;
}
