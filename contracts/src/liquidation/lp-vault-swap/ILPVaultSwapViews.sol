// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILPVaultSwapViews
/// @notice Committed-operator registry views of LPVaultSwap and its implementation immutables and constants.
interface ILPVaultSwapViews {
    /// @notice Whether an address is a registered committed operator. `liquidate` never reads it.
    function isApprovedKeeper(
        address keeper
    ) external view returns (bool approved);

    /// @notice Number of registered committed operators, frozen ones included.
    function approvedKeeperCount() external view returns (uint256 count);

    /// @notice Number of registered committed operators the MarketRegistry has not frozen.
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
