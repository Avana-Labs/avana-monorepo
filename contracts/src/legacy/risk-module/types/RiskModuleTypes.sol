// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice USD exposure a pledge books against the caps.
/// @dev `usdCharge` is rounded up; `sliceUsd <= usdCharge`.
struct PledgeCharge {
    // Stress-floor booked USD value of the pledge, 8 decimals.
    uint256 usdCharge;
    // Part of usdCharge booked against the top-up slice, 8 decimals.
    uint256 sliceUsd;
    bool rescue;
    // Units added to the record's rescue units, at most the pledged liquidity.
    uint128 rescueUnits;
}

/// @notice Implementation immutables of the LegacyRiskModule and of each of its logic contracts, all per chain.
struct RiskModuleImmutables {
    address marketRegistry;
    address parameterStore;
    // Collateralization, the caller of `checkPledge`.
    address collateralization;
    // The AaveAdapter fixed proxy, the caller of the borrow-side checks.
    address adapter;
    // LPVaultSwap fixed proxy, read for `activeKeeperCount`.
    address lpVaultSwap;
}

/// @notice The six immutable logic contracts the LegacyRiskModule calls for its check bodies.
/// @dev The LegacyRiskModule constructor checks every `logicConfig()`.
struct RiskModuleLogics {
    address drift;
    address breaker;
    address pledge;
    address borrow;
    address status;
    address dynamicCap;
}

/// @notice A market's current borrow cap interval: when it started and the cap fixed for it.
/// @dev One storage slot. `cap` is `D_start + L(D_start)` in 8-decimal USD, saturated at `2^192 - 1`.
struct DynamicCap {
    // Start of the interval, seconds.
    uint64 intervalStart;
    // The interval's cap on the market's debt after a borrow, 8-decimal USD.
    uint192 cap;
}
