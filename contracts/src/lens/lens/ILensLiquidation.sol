// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PauseState} from "../../types/PauseState.sol";
import {PriceView} from "../../types/PriceView.sol";
import {DebtPriceView} from "./types/DebtPriceView.sol";
import {LiquidationPreview} from "./types/LiquidationPreview.sol";

/// @title ILensLiquidation
/// @notice Price, pause-state and liquidation-preview views of the Lens.
interface ILensLiquidation {
    /// @notice Returns a market's price state report.
    function getPriceState(
        address vaultToken
    ) external view returns (PriceView memory priceView);

    /// @notice Returns a debt reserve's Aave price source, price and freshness for borrowing and liquidation.
    /// @dev Reverts `UnknownDebtReserve` for an unapproved reserve. Fixed-price reserves report age 0.
    function getDebtPriceState(
        address spoke,
        uint256 debtReserveId
    ) external view returns (DebtPriceView memory priceView);

    /// @notice Returns a Hub's pause state held by the MarketRegistry.
    /// @dev Liquidation, pending settlement, repay, fee collection and debt-free withdrawal are open in every state.
    /// @return state `None`, `Frozen` or `Paused`.
    function getApplicationState(
        address hub
    ) external view returns (PauseState state);

    /// @notice Returns a Hub's pause reason.
    /// @return reason `PauseReason` ordinal.
    function getPauseReason(
        address hub
    ) external view returns (uint8 reason);

    /// @notice Returns the liquidation gates, Aave's sizing, ready-to-send `LiquidationParams` and expected amounts.
    /// @dev Advisory only; LPVaultSwap recomputes every check on execution.
    function previewLiquidation(
        address proxy,
        uint256 debtReserveId,
        uint256 deadline
    ) external view returns (LiquidationPreview memory preview);
}
