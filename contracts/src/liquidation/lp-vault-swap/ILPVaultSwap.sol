// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashReceiver} from "../../flash/IFlashReceiver.sol";
import {ILPVaultSwapBase} from "./ILPVaultSwapBase.sol";
import {DeleverageRequest, LiquidationParams, LiquidationResult} from "./types/LPVaultSwapTypes.sol";

/// @title ILPVaultSwap
/// @notice The chain's liquidator: seizes vault-token collateral through Aave and settles it in the debt asset.
/// @dev UUPS proxy; only the timelock can upgrade it. Never reads the pause state or circuit breakers.
interface ILPVaultSwap is ILPVaultSwapBase, IFlashReceiver {
    /// @notice Initializes the proxy storage.
    /// @dev Grants `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` to `timelock` only.
    function initialize(
        address timelock,
        address[] calldata initialKeepers
    ) external;

    /// @notice Registers a committed operator, which commits to liquidate every account below HF 1 on the chain.
    /// @dev `APPLICATION_ADMIN` only. Registration grants no power over `liquidate`.
    function addKeeper(
        address keeper
    ) external;

    /// @notice Removes a committed operator from the registry.
    /// @dev `APPLICATION_ADMIN` only. Reverts `KeeperFloor` if fewer than `KEEPER_FLOOR` active operators would remain.
    function removeKeeper(
        address keeper
    ) external;

    /// @notice Repays part of a borrower's debt from the liquidity of one of its pledged records.
    /// @dev Only the AaveAdapter, while it holds the lock.
    function deleverage(
        DeleverageRequest calldata r
    ) external returns (uint256 debtRepaid, uint256 debtAssetOut);

    /// @notice Liquidates one account against one debt reserve and settles it in the debt asset in the same call.
    /// @dev Any caller; pulls `params.debtToCover` from the caller and takes no flash loan.
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

    /// @notice Whether an address is a registered committed operator. `liquidate` never reads it.
    function isApprovedKeeper(
        address keeper
    ) external view returns (bool approved);

    /// @notice Number of registered committed operators.
    function approvedKeeperCount() external view returns (uint256 count);

    /// @notice Number of registered committed operators; new borrowing halts when it is 0.
    function activeKeeperCount() external view returns (uint256 count);

    /// @notice Most transfers `onFlashLoan` makes to repay the flash source by balance delta.
    function MAX_REPAY_TRANSFERS() external view returns (uint256 count);

    /// @notice The committed-operator registry.
    function getKeepers() external view returns (address[] memory keepers);

    /// @notice Minimum number of active committed operators `removeKeeper` leaves.
    function KEEPER_FLOOR() external view returns (uint256 floor);

    /// @notice Most registered committed operators per chain.
    function MAX_KEEPERS() external view returns (uint256 max);

    /// @notice The `APPLICATION_ADMIN` role identifier.
    function APPLICATION_ADMIN() external view returns (bytes32 role);

    /// @notice The AvanaTimelock, the only holder of `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN`.
    function TIMELOCK() external view returns (address timelock);

    /// @notice Protocol lock contract.
    function LOCK() external view returns (address lock);

    /// @notice AaveAdapter fixed proxy address.
    function AAVE_ADAPTER() external view returns (address adapter);

    /// @notice Collateralization contract.
    function COLLATERALIZATION() external view returns (address collateralization);

    /// @notice MarketRegistry fixed proxy address.
    function MARKET_REGISTRY() external view returns (address registry);

    /// @notice ParameterStore fixed proxy address.
    function PARAMETER_STORE() external view returns (address store);

    /// @notice PayoutEscrow, which receives any escrowable payout whose gas-limited transfer failed.
    function PAYOUT_ESCROW() external view returns (address escrow);

    /// @notice Gas forwarded to each gas-limited escrowable payout transfer.
    function PAYOUT_TRANSFER_GAS() external view returns (uint256 gas);
}
