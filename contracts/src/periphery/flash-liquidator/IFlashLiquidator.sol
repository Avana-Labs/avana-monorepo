// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashLiquidatorErrors} from "./IFlashLiquidatorErrors.sol";
import {IFlashLiquidatorEvents} from "./IFlashLiquidatorEvents.sol";
import {FlashLiquidationRequest} from "./types/FlashLiquidationRequest.sol";

/// @title IFlashLiquidator
/// @notice Flash liquidation helper: borrows the debt asset from Aave V3 and runs `LPVaultSwap.liquidate` in the loan.
/// @dev Immutable, no owner; holds no funds or allowances between transactions.
interface IFlashLiquidator is IFlashLiquidatorErrors, IFlashLiquidatorEvents {
    /// @notice Liquidates through `LPVaultSwap.liquidate`, funded by a flash loan of the debt asset.
    /// @dev The context is cleared last, so reentry during the payout reverts `ContextActive`.
    /// @return payout Net debt asset paid to the recipient.
    function flashLiquidate(
        FlashLiquidationRequest calldata request
    ) external returns (uint256 payout);

    /// @notice Aave V3 `flashLoan` callback: runs the liquidation and approves the Pool for exactly `F + premium`.
    /// @dev Reverts `InvalidFlashCallback` unless the call matches the open, unused context.
    /// @param initiator The `flashLoan` caller; must be this helper.
    /// @param params `abi.encode(LiquidationParams)`, bound to the context by hash.
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool success);

    /// @notice Claims the helper's whole PayoutEscrow credit of `token` to the variant's claim recipient.
    /// @dev Reverts `ContextActive` while a `flashLiquidate` context is open.
    function claimEscrowed(
        address token
    ) external returns (uint256 amount);

    /// @notice What the Pool can lend of `asset` now; 0 unless the reserve is active, unpaused and flash-enabled.
    function maxFlashLoan(
        address asset
    ) external view returns (uint256 available);

    /// @notice The premium the Pool charges this helper for `amount` of `asset`, rounded up.
    /// @dev 0 while the helper holds `FLASH_BORROWER` on the Pool's ACLManager.
    function flashPremium(
        address asset,
        uint256 amount
    ) external view returns (uint256 premium);

    /// @notice The chain's Aave V3 Pool, the lender of every debt asset.
    function POOL() external view returns (address pool);

    /// @notice The chain's LPVaultSwap.
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice The chain's MarketRegistry.
    function MARKET_REGISTRY() external view returns (address registry);

    /// @notice The chain's ParameterStore.
    function PARAMETER_STORE() external view returns (address store);
}
