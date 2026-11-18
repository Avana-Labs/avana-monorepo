// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PauseState} from "../../types/MarketTypes.sol";
import {PriceView} from "../../types/OracleTypes.sol";
import {ILensAccount} from "./ILensAccount.sol";
import {ILensActions} from "./ILensActions.sol";
import {ILensErrors} from "./ILensErrors.sol";
import {ILensFees} from "./ILensFees.sol";
import {ILensHubAssets} from "./ILensHubAssets.sol";
import {ILensMarket} from "./ILensMarket.sol";
import {ILensMarkets} from "./ILensMarkets.sol";
import {ILensPositions} from "./ILensPositions.sol";
import {ILensPreview} from "./ILensPreview.sol";
import {ILensRisk} from "./ILensRisk.sol";
import {ILensSpeed} from "./ILensSpeed.sol";
import {
    CloseAccountView,
    DebtPriceView,
    DeleverageSizing,
    LiquidationPreview,
    RemovalSizing
} from "./types/LensTypes.sol";

/// @title ILens
/// @notice Read-only views of one chain's accounts, markets, prices, risk state and liquidation and action previews.
/// @dev Advisory only; every view reverts with `Locked()` while the Lock is held.
interface ILens is
    ILensErrors,
    ILensAccount,
    ILensMarket,
    ILensRisk,
    ILensPreview,
    ILensMarkets,
    ILensPositions,
    ILensFees,
    ILensActions,
    ILensHubAssets,
    ILensSpeed
{
    /// @notice Returns the largest page size `getRecords` and `checkRecordBacking` accept.
    function LENS_MAX_PAGE() external view returns (uint256 maxPage);

    /// @notice Returns the dust margin `previewLiquidation` applies when sizing a whole-debt `debtToCover`.
    function LENS_DUST_MARGIN_BPS() external view returns (uint256 marginBps);

    /// @notice Returns the nine modules the Lens forwards to.
    /// @return modules Account, Market, Price, Liquidation, Risk, Preview, Markets, Positions and Speed modules.
    function MODULES() external view returns (address[9] memory modules);

    /// @notice Returns the Collateralization contract.
    function COLLATERALIZATION() external view returns (address collateralization);

    /// @notice Returns the ProxyManager.
    function PROXY_MANAGER() external view returns (address proxyManager);

    /// @notice Returns the AaveAdapter fixed proxy address.
    function ADAPTER() external view returns (address adapter);

    /// @notice Returns the protocol Lock.
    function LOCK() external view returns (address lock);

    /// @notice Returns the MarketRegistry fixed proxy address.
    function MARKET_REGISTRY() external view returns (address marketRegistry);

    /// @notice Returns the ParameterStore fixed proxy address.
    function PARAMETER_STORE() external view returns (address parameterStore);

    /// @notice Returns the RiskModule fixed proxy address.
    function RISK_MODULE() external view returns (address riskModule);

    /// @notice Returns the LPVaultSwap fixed proxy address.
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice Returns the PayoutEscrow.
    function PAYOUT_ESCROW() external view returns (address payoutEscrow);

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

    /// @notice Returns the most units the account can withdraw and keep a target health factor.
    /// @param targetHealthFactor Target, WAD; raised to `max(1e18, hardHealthFloor)` with debt.
    function previewMaxWithdraw(
        address wallet,
        uint256 marketId,
        uint256 targetHealthFactor
    ) external view returns (RemovalSizing memory sizing);

    /// @notice Returns the fewest units of one record whose repay with collateral reaches a target health factor.
    /// @param targetHealthFactor Target, WAD; raised to 1e18.
    function previewDeleverageTo(
        address wallet,
        uint256 marketId,
        bytes32 positionKey,
        uint256 debtReserveId,
        uint256 targetHealthFactor
    ) external view returns (DeleverageSizing memory sizing);

    /// @notice Returns every debt the account repays and every record it withdraws to close.
    /// @param deadline Last `block.timestamp` the repay-all calls may be included at.
    /// @return close The view; empty before the proxy is deployed.
    function previewCloseAccount(
        address wallet,
        uint256 marketId,
        uint256 deadline
    ) external view returns (CloseAccountView memory close);
}
