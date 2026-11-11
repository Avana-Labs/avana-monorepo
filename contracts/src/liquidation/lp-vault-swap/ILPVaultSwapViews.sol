// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILPVaultSwapViews
/// @notice Committed-operator registry views of LPVaultSwap and its implementation immutables and constants. The
/// registry gates no call (Q-404).
interface ILPVaultSwapViews {
    /// @notice Whether an address is a registered committed operator. `liquidate` never reads it.
    /// @param keeper Address to check.
    /// @return approved True when registered.
    /// @custom:spec REQ-SWAP-001, REQ-SWAP-032
    function isApprovedKeeper(
        address keeper
    ) external view returns (bool approved);

    /// @notice Number of registered committed operators, frozen ones included; the borrowing halt and `KEEPER_FLOOR`
    /// use `activeKeeperCount` instead.
    /// @return count Registered operator count.
    /// @custom:spec REQ-SWAP-034, REQ-SWAP-039
    function approvedKeeperCount() external view returns (uint256 count);

    /// @notice Number of registered committed operators the MarketRegistry has not frozen; the RiskModule halts new
    /// borrowing and withdraw-with-debt on the chain while it is 0, and `KEEPER_FLOOR` applies to it. Liquidation never
    /// halts on it.
    /// @return count Active committed-operator count.
    /// @custom:spec REQ-SWAP-034, REQ-SWAP-107, Q-242, Q-404
    function activeKeeperCount() external view returns (uint256 count);

    /// @notice Most transfers `onFlashLoan` makes, inside `deleverage`, to repay the flash source by balance delta
    /// (implementation constant); a liquidation takes no flash loan.
    /// @return count 4: enough for USDT's fee bounds (at most 19 bps and 50 USDT per transfer), whose residual after each
    /// transfer is the fee on that transfer: at most 50e6, then 95,000, then 180, then 0 raw units.
    /// @custom:spec REQ-SWAP-122
    function MAX_REPAY_TRANSFERS() external view returns (uint256 count);

    /// @notice The committed-operator registry.
    /// @return keepers Registered committed operators.
    /// @custom:spec REQ-SWAP-032
    function getKeepers() external view returns (address[] memory keepers);

    /// @notice Minimum number of active committed operators `removeKeeper` leaves (implementation immutable
    /// `keeperFloor = 1`, Avana's keeper at launch). New borrowing halts only when 0 active committed operators remain
    /// on the chain (Q-400).
    /// @return floor Keeper floor.
    /// @custom:spec REQ-SWAP-034, Q-400
    function KEEPER_FLOOR() external view returns (uint256 floor);

    /// @notice Most registered committed operators per chain (implementation constant 32).
    /// @return max Keeper limit.
    /// @custom:spec REQ-SWAP-032, REQ-SWAP-033, Q-400
    function MAX_KEEPERS() external view returns (uint256 max);

    /// @notice The `APPLICATION_ADMIN` role identifier.
    /// @return role `keccak256("APPLICATION_ADMIN")`.
    /// @custom:spec REQ-SWAP-040
    function APPLICATION_ADMIN() external view returns (bytes32 role);

    /// @notice The AvanaTimelock, the only holder of `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN`; set once by
    /// `initialize`, and `_grantRole` refuses either admin role to any other account.
    /// @return timelock Address.
    /// @custom:spec REQ-SWAP-040, REQ-ACCESS-153, Q-259
    function TIMELOCK() external view returns (address timelock);

    /// @notice Protocol lock contract (implementation immutable).
    /// @return lock Address.
    /// @custom:spec REQ-SWAP-002
    function LOCK() external view returns (address lock);

    /// @notice AaveAdapter fixed proxy address, which burns seized vault tokens (implementation immutable).
    /// @return adapter Address.
    /// @custom:spec REQ-SWAP-020, REQ-SWAP-092
    function AAVE_ADAPTER() external view returns (address adapter);

    /// @notice Immutable Collateralization contract (seizure snapshot, debit, unwind, pending balance).
    /// @return collateralization Address.
    /// @custom:spec REQ-SWAP-015, REQ-SWAP-020
    function COLLATERALIZATION() external view returns (address collateralization);

    /// @notice MarketRegistry fixed proxy address (markets, debt reserves, routes).
    /// @return registry Address.
    /// @custom:spec REQ-SWAP-004, REQ-SWAP-047
    function MARKET_REGISTRY() external view returns (address registry);

    /// @notice ParameterStore fixed proxy address (every risk parameter).
    /// @return store Address.
    /// @custom:spec REQ-SWAP-047
    function PARAMETER_STORE() external view returns (address store);

    /// @notice Immutable PayoutEscrow (implementation immutable), the payout escrow: receives, credited to its
    /// recipient, an Avana fee, borrower surplus, route residue or dust leg whose gas-limited transfer failed (Q-401);
    /// the caller's payout `keeperOut` is never escrowed.
    /// @return escrow Address.
    /// @custom:spec REQ-SWAP-076, REQ-SWAP-082, REQ-ESCROW-002, Q-214
    function PAYOUT_ESCROW() external view returns (address escrow);

    /// @notice Gas forwarded to each gas-limited escrowable payout transfer (`payoutTransferGas`,
    /// implementation constant 100,000, changed only by an upgrade at the normal delay).
    /// @return gas Gas units.
    /// @custom:spec REQ-SWAP-076, REQ-SWAP-083, Q-214
    function PAYOUT_TRANSFER_GAS() external view returns (uint256 gas);
}
