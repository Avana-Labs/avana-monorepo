// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILiquidationModule} from "avana/liquidation/interfaces/ILiquidationModule.sol";
import {Swap} from "avana/periphery/libraries/SwapCalls.sol";

/// @title IFlashLiquidator
/// @notice The liquidation bot's flash path: borrows the debt asset from the chain's Aave V3 Pool, liquidates through
/// the LiquidationModule (paid in both pool tokens), sells the tokens with the bot's route, repays the loan and sends
/// the rest to the bot.
/// @dev Outside the protocol. Not upgradeable, no admin, no funds or allowances between transactions. Only `OPERATOR`
/// (the bot's signer) may call it, because the Aave DAO's `FLASH_BORROWER` grant waives the premium for this address
/// and is meant for Avana's committed liquidations only.
interface IFlashLiquidator {
    /// @notice One flash liquidation.
    /// @param params Passed to `LiquidationModule.liquidate`; `debtToCover` is set to `flashAmount` and `receiver` to
    /// this contract.
    /// @param flashAmount Debt asset borrowed and offered to the liquidation; the module refunds what Aave did not take.
    /// @param swaps The route from the pool tokens to the debt asset.
    /// @param maxTopUp Most debt asset pulled from the operator when the sale does not cover the loan (a committed
    /// operator liquidates at a loss when it must).
    /// @param minProfit Least debt asset left after the loan, or zero.
    /// @param recipient Receiver of the profit and of any unsold pool token; zero means the operator.
    struct Request {
        ILiquidationModule.LiquidationParams params;
        uint256 flashAmount;
        Swap[] swaps;
        uint256 maxTopUp;
        uint256 minProfit;
        address recipient;
    }

    /// @notice A zero constructor address.
    error InvalidAddress(address account);
    /// @notice The caller is not the operator.
    error NotOperator(address caller);
    /// @notice A zero flash amount.
    error InvalidAmount();
    /// @notice The flash-loan callback does not match the loan this contract opened.
    error InvalidFlashCallback();
    /// @notice The sale left the loan short by more than `maxTopUp`.
    error TopUpExceeded(uint256 topUp, uint256 maxTopUp);
    /// @notice The profit is below `minProfit`.
    error ProfitTooLow(uint256 profit, uint256 minProfit);

    /// @notice A flash liquidation completed.
    event FlashLiquidated(
        address indexed account,
        uint256 indexed marketId,
        address indexed asset,
        uint256 flashAmount,
        uint256 premium,
        uint256 debtRepaid,
        uint256 topUp,
        uint256 profit
    );

    /// @notice Runs one flash liquidation. Only `OPERATOR`.
    /// @return profit Debt asset sent to the recipient after the loan and its premium.
    function flashLiquidate(
        Request calldata request
    ) external returns (uint256 profit);

    /// @notice The premium the Pool charges this contract for `amount`: zero while it holds `FLASH_BORROWER`.
    function flashPremium(
        uint256 amount
    ) external view returns (uint256 premium);

    /// @notice Whether the Aave DAO has granted this contract `FLASH_BORROWER` on the Pool.
    function isFlashBorrower() external view returns (bool);

    /// @notice The Aave V3 Pool that lends the debt asset.
    function POOL() external view returns (address pool);

    /// @notice The LiquidationModule.
    function LIQUIDATION_MODULE() external view returns (address module);

    /// @notice The RiskModule that lists the markets.
    function RISK_MODULE() external view returns (address riskModule);

    /// @notice The LPVault that names each market's pool tokens.
    function LP_VAULT() external view returns (address lpVault);

    /// @notice The bot's signer, the only caller.
    function OPERATOR() external view returns (address operator);
}
