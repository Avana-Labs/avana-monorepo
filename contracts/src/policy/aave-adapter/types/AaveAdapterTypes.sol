// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionRef} from "../../../types/PositionTypes.sol";

/// @notice The chain's fixed dependencies of the AaveAdapter implementation and of each of its logic contracts.
/// @dev Every field is non-zero; the router checks each logic contract was built with the same values.
struct AaveAdapterImmutables {
    address proxyManager;
    address collateralization;
    address riskModule;
    address marketRegistry;
    address parameterStore;
    address lpVaultSwap;
    address lock;
    address vaultTokenFactory;
}

/// @notice The four logic contracts of an AaveAdapter implementation.
struct AaveAdapterLogics {
    // pledge, borrow, repay.
    address user;
    // withdraw, repayAllAndWithdraw, collectFees, releaseZeroCredit, refreshDebtMark.
    address exit;
    // removeLiquidity, recredit, repayWithCollateral.
    address collateral;
    // burnSeized, deleverageRepay, deleverageRelease.
    address settlement;
}

/// @notice The binding the AaveAdapter stores for a proxy in the pledge that creates it, never changed afterwards.
/// @dev Exits read it instead of the MarketRegistry.
struct AdapterAccount {
    address spoke;
    uint256 marketId;
    address vaultToken;
    uint256 reserveId;
}

/// @notice Arguments of `AaveAdapter.repayWithCollateral`.
/// @dev Asset amounts are debt-asset base units; `minHealthFactor` is WAD.
struct RepayWithCollateralParams {
    uint256 marketId;
    PositionRef position;
    uint128 units;
    uint256 debtReserveId;
    uint256[] minAmounts;
    uint256 minDebtRepaid;
    // Least debt asset paid to the wallet after the flash loan and its premium.
    uint256 minAssetOut;
    uint256 deadline;
    // Least health factor after the call while debt remains.
    uint256 minHealthFactor;
}
