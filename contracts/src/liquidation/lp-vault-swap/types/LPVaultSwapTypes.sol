// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionRef} from "../../../types/PositionTypes.sol";

/// @notice Arguments of `deleverage`, built by the AaveAdapter from the borrower's `repayWithCollateral` call.
/// @dev Amounts are in base units of the debt reserve's asset.
struct DeleverageRequest {
    address proxy;
    // Receives the leftover debt asset and any route residue.
    address wallet;
    address spoke;
    uint256 marketId;
    address vaultToken;
    PositionRef position;
    uint128 units;
    uint256 debtReserveId;
    // Least raw amount of each pool token the unwind must return, market token order.
    uint256[] minAmounts;
    uint256 minDebtRepaid;
}

/// @notice Per-chain addresses and keeper floor every LPVaultSwap implementation and logic contract is built with.
// forge-lint: disable-next-item(pascal-case-struct)
struct LPVaultSwapImmutables {
    address lock;
    address aaveAdapter;
    address collateralization;
    address marketRegistry;
    address parameterStore;
    address payoutEscrow;
    // Fewest active committed operators removeKeeper leaves.
    uint256 keeperFloor;
}

/// @notice The three logic contracts the LPVaultSwap implementation delegatecalls, each an implementation immutable.
// forge-lint: disable-next-item(pascal-case-struct)
struct LPVaultSwapLogics {
    address liquidation;
    address pending;
    address deleverage;
}

/// @notice Arguments of `liquidate`, the one liquidation entry point.
/// @dev Amounts are in base units of the debt reserve's asset.
struct LiquidationParams {
    address proxy;
    // Collateral market to seize; must equal the proxy's MARKET_ID().
    uint256 marketId;
    uint256 debtReserveId;
    // Debt asset pulled from msg.sender; the amount measured bounds Aave's liquidationCall.
    uint256 debtToCover;
    RouteMode routeMode;
    // Least raw amount of each pool token the unwind must return; empty for none.
    uint256[] minAmounts;
    uint256 deadline;
    // Smallest keeperOut the caller accepts; keeperOut includes the returned funding.
    uint256 minPayout;
    // Most extra debt asset the call may pull to cover recovery below the floor; 0 disables the top-up.
    uint256 maxShortfall;
}

/// @notice Outcome of `liquidate`.
/// @dev Amounts other than `unitsSeized` and `amountsOut` are in base units of the repaid debt asset.
struct LiquidationResult {
    address debtAsset;
    uint256 debtRepaid;
    uint256 unitsSeized;
    // Raw amount of each pool token the unwind returned, market token order.
    uint256[] amountsOut;
    uint256 callerFunds;
    uint256 recovered;
    // Recovery floor, tested on recovered + shortfall.
    uint256 minOut;
    uint256 avanaFee;
    uint256 keeperReward;
    // Debt asset paid to the caller: unused funding, recovered principal and keeper reward.
    uint256 keeperOut;
    // Full borrower surplus; when a deficit is booked the First-Loss Reserve takes part of it.
    uint256 borrowerSurplus;
    uint256 shortfall;
}

/// @notice Swap-route mode chosen by the caller of `liquidate`.
enum RouteMode {
    PrimaryThenBackup,
    BackupOnly
}
