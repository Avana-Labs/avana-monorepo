// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAaveV3FlashLoanReceiver
/// @notice Callback of the Aave V3 Pool `flashLoan`, copied from
/// `src/contracts/misc/flashloan/interfaces/IFlashLoanReceiver.sol` of aave-dao/aave-v3-origin (v3.4), with
/// identical selectors.
/// @dev Implemented by: the AaveV3FlashSource of each chain. The V3 Pool holds no reentrancy lock around the callback,
/// so the receiver checks `msg.sender == POOL`, `initiator == address(this)`, `assets.length == 1` and an active
/// transient flash context set by its own `flashLoan` before acting, and approves the Pool for exactly
/// `amounts[0] + premiums[0]`.
interface IAaveV3FlashLoanReceiver {
    /// @notice Executes the operation funded by the flash loan; must return true and leave the Pool approved for
    /// amount plus premium. Source: `IFlashLoanReceiver.sol`.
    /// @dev Called by: the Aave V3 Pool inside `flashLoan`.
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}
