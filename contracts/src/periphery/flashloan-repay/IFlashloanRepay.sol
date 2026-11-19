// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Swap} from "../libraries/SwapCalls.sol";

/// @title IFlashloanRepay
/// @notice Repay with collateral, in part or in full. The wallet calls `AaveAdapter.allowWithdraw(this, positionKey,
/// liquidity, abi.encode(RepayParams))`; this helper flash-borrows the debt asset from the Aave V3 Pool, repays the
/// wallet's debt through the adapter, withdraws `liquidity` of the position, runs the wallet's swaps, repays the flash
/// loan and sends everything left (debt asset and both pool tokens) to the wallet.
/// @dev Outside the Avana core. Not upgradeable, no admin, no funds or allowances between transactions. The adapter's
/// allowance lasts one call and covers one position, and the adapter reverts unless the account's health factor ends at
/// least where it started. The design record is `DESIGN.md` next to this file.
interface IFlashloanRepay {
    /// @notice What the wallet asks for, passed through `allowWithdraw` as `data`.
    /// @param reserveId The Spoke reserve of the debt to repay.
    /// @param amount Debt to repay; `type(uint256).max`, or anything above the debt, repays all of it.
    /// @param liquidity Liquidity to withdraw from the position (part of it, at most the allowance).
    /// @param amount0Min Least token0 the withdrawal must return.
    /// @param amount1Min Least token1 the withdrawal must return.
    /// @param swaps The wallet's route from the pool tokens to the debt asset.
    struct RepayParams {
        uint256 reserveId;
        uint256 amount;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        Swap[] swaps;
    }

    /// @notice A zero constructor address.
    error InvalidAddress(address account);
    /// @notice `onWithdrawAllowed` was not called by the AaveAdapter.
    error NotAdapter(address caller);
    /// @notice The flash-loan callback does not match the loan this helper opened.
    error InvalidFlashCallback();
    /// @notice The account has no debt in the reserve.
    error NothingToRepay(address account, uint256 reserveId);
    /// @notice The swaps left less of the debt asset than the flash loan and its premium.
    error InsufficientProceeds(uint256 balance, uint256 owed);

    /// @notice A wallet repaid debt with part of a position.
    event RepaidWithCollateral(
        address indexed wallet,
        bytes32 indexed positionKey,
        address indexed asset,
        uint256 repaid,
        uint256 premium,
        uint128 liquidity
    );

    /// @notice The AaveAdapter whose allowance this helper uses.
    function ADAPTER() external view returns (address adapter);

    /// @notice The Aave V3 Pool that lends the debt asset.
    function POOL() external view returns (address pool);

    /// @notice The LPVault that holds the positions.
    function LP_VAULT() external view returns (address lpVault);

    /// @notice The RiskModule that lists the markets.
    function RISK_MODULE() external view returns (address riskModule);
}
