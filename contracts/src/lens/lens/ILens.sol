// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILensAccount} from "./ILensAccount.sol";
import {ILensActions} from "./ILensActions.sol";
import {ILensErrors} from "./ILensErrors.sol";
import {ILensFees} from "./ILensFees.sol";
import {ILensHubAssets} from "./ILensHubAssets.sol";
import {ILensLiquidation} from "./ILensLiquidation.sol";
import {ILensMarket} from "./ILensMarket.sol";
import {ILensMarkets} from "./ILensMarkets.sol";
import {ILensPositions} from "./ILensPositions.sol";
import {ILensPreview} from "./ILensPreview.sol";
import {ILensRisk} from "./ILensRisk.sol";
import {ILensSizing} from "./ILensSizing.sol";
import {ILensSpeed} from "./ILensSpeed.sol";

/// @title ILens
/// @notice Read-only views of one chain's accounts, markets, prices, risk state and liquidation and action previews.
/// @dev Advisory only; every view reverts with `Locked()` while the Lock is held.
interface ILens is
    ILensErrors,
    ILensAccount,
    ILensMarket,
    ILensLiquidation,
    ILensRisk,
    ILensPreview,
    ILensMarkets,
    ILensPositions,
    ILensFees,
    ILensActions,
    ILensSizing,
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
}
