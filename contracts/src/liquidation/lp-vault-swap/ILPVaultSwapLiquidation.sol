// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationParams} from "./types/LiquidationParams.sol";
import {LiquidationResult} from "./types/LiquidationResult.sol";

/// @title ILPVaultSwapLiquidation
/// @notice The entry points of LPVaultSwap open to any caller: `liquidate` and `settlePending`.
/// @dev Neither reads the MarketRegistry pause state, a breaker or the committed-operator registry.
interface ILPVaultSwapLiquidation {
    /// @notice Liquidates one account against one debt reserve and settles it in the debt asset in the same call.
    /// @dev Any caller that is not frozen; pulls `params.debtToCover` from the caller and takes no flash loan.
    function liquidate(
        LiquidationParams calldata params
    ) external returns (LiquidationResult memory result);

    /// @notice Burns vault tokens left pending by an unsettled seizure and adds their value to the First-Loss Reserve.
    /// @dev Any caller; the caller supplies and receives nothing.
    /// @param debtReserveId The market's settlement reserve.
    function settlePending(
        uint256 marketId,
        uint256 debtReserveId
    ) external returns (uint256 units, uint256[] memory amounts, uint256 added);
}
