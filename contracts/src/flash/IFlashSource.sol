// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IFlashSource
/// @notice The chain's source of flash liquidity for `deleverage` (repay with collateral).
/// @dev One per chain, replaceable through the governance role. Its `LENDER()` must not be a Hub recorded on the chain.
interface IFlashSource {
    error NotLPVaultSwap();

    /// @notice A loan of this source is already open.
    error FlashLoanActive();

    error ZeroAddress();

    /// @notice `amount` exceeds available liquidity, or the reserve is paused, inactive or not flash-loanable.
    error InsufficientFlashLiquidity(uint256 available);

    /// @notice The premium fails the exact check `premium * 1e4 <= maxFlashFeeBps * amount`.
    /// @param maxPremium Largest premium that passes the check, debt asset base units.
    error FlashFeeTooHigh(uint256 premium, uint256 maxPremium);

    /// @notice The lender is the Hub of the Spoke being liquidated.
    error FlashSourceIsHub();

    /// @notice The lender's callback failed authentication or arrived outside an active flash context.
    error InvalidFlashCallback();

    /// @notice After `onFlashLoan`, the source holds less of the asset than the lender is owed.
    error FlashRepayShort(uint256 balance, uint256 owed);

    /// @notice A flash loan was taken and repaid.
    event FlashLoanServed(address indexed asset, uint256 amount, uint256 premium);

    /// @notice Lends `amount` of `asset` to LPVaultSwap, calls its `onFlashLoan`, and repays the lender.
    /// @dev Only LPVaultSwap; reverts `FlashFeeTooHigh` if the premium exceeds `maxFlashFeeBps`.
    /// @param spokeHub Hub of the Spoke being liquidated.
    function flashLoan(
        address asset,
        uint256 amount,
        address spokeHub,
        bytes calldata context
    ) external returns (uint256 premium);

    /// @notice Returns the most the lender can lend of `asset` now.
    /// @dev Aave V3: 0 when the reserve is inactive, paused or not flash-loanable. A frozen reserve can still lend.
    function maxFlashLoan(
        address asset
    ) external view returns (uint256 available);

    /// @notice Returns the source's quote of the premium on `amount` of `asset`, never below the lender's charge.
    function flashPremium(
        address asset,
        uint256 amount
    ) external view returns (uint256 premium);

    /// @notice Returns the pool or Hub the loan draws from, never an intermediate contract.
    function LENDER() external view returns (address lender);

    /// @notice Returns LPVaultSwap, the only borrower.
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice Returns the ParameterStore that holds `maxFlashFeeBps`.
    function PARAMETER_STORE() external view returns (address parameterStore);
}
