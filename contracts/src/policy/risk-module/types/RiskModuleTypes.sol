// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketSpeedLimits, SpeedLimit} from "../../parameter-store/types/ParameterStoreTypes.sol";

/// @notice Inputs of the borrow-speed check of one borrow.
struct BorrowSpeedInputs {
    // keccak256(abi.encode(hub, asset)), key of the debt window.
    bytes32 debtKey;
    address hub;
    address asset;
    // The borrow's charge in the market window, rounded up (8-decimal USD).
    uint256 amountUsd;
    // USD debt of the market's CDP Spoke over its debt reserves (8-decimal USD).
    uint256 marketBase;
    // Asset owed to the Hub by every CDP Spoke the MarketRegistry records (asset base units).
    uint256 debtBase;
    MarketSpeedLimits market;
    SpeedLimit debt;
}

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

/// @notice Implementation immutables of the RiskModule and of each of its logic contracts, all per chain.
struct RiskModuleImmutables {
    address marketRegistry;
    address parameterStore;
    // Collateralization, the caller of `checkPledge`.
    address collateralization;
    // The AaveAdapter fixed proxy, the caller of the borrow-side checks.
    address adapter;
    // LPVaultSwap fixed proxy, read for `activeKeeperCount`.
    address lpVaultSwap;
    // The chain's AvanaTimelock, the only holder of `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN`.
    address timelock;
}

/// @notice The six immutable logic contracts the RiskModule calls for its check bodies.
/// @dev The RiskModule constructor checks every `logicConfig()`.
struct RiskModuleLogics {
    address drift;
    address breaker;
    address pledge;
    address borrow;
    address status;
    address speed;
}

/// @notice Which speed window a key names: a market's borrow window (key `bytes32(marketId)`), a (funding Hub, asset)
/// borrow window (key `keccak256(abi.encode(hub, asset))`) or a market's pledge window (key `bytes32(marketId)`).
enum SpeedScope {
    MarketBorrow,
    DebtBorrow,
    MarketPledge
}

/// @notice One speed window as the next check would see it now.
/// @dev With `unavailable` set a read failed and every other field is 0.
struct SpeedView {
    uint256 limit;
    // Charges still counting.
    uint256 used;
    // Room for the next charge: limit less used, floored at 0.
    uint256 available;
    // Time the next charges stop counting, or 0.
    uint64 moreAt;
    // Charges that stop counting at moreAt.
    uint256 moreAmount;
    bool unavailable;
}

/// @notice One net-flow speed window: the bucket `[start, start + window)`, the one before it, and its base.
/// @dev Two storage slots; `prev + curr` never exceeds the scope's `max`, which fits `uint96`.
struct SpeedWindow {
    // Start of the current bucket, seconds.
    uint64 start;
    // Net charges of the bucket before the current one.
    uint96 prev;
    // Net charges of the current bucket.
    uint96 curr;
    // The window-start base the limit is computed on, written with the bucket's first charge.
    uint248 base;
    // True once a charge opened the bucket starting at `start`, so `base` belongs to it.
    bool opened;
}
