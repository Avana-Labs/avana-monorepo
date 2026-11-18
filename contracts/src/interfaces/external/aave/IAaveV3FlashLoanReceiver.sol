// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAaveV3FlashLoanReceiver
/// @notice Callback of the Aave V3 Pool `flashLoan`.
/// @dev The Pool holds no reentrancy lock around the callback, so the receiver checks caller, initiator and context.
interface IAaveV3FlashLoanReceiver {
    /// @notice Executes the operation funded by the flash loan; must return true and leave the Pool approved for amount
    /// plus premium.
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}
