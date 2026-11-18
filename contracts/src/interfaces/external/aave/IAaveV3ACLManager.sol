// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.28;

/// @title IAaveV3ACLManager
/// @notice Subset of the Aave V3 ACLManager for the `FLASH_BORROWER` role, which waives the `flashLoan` premium.
/// @dev Copied from aave-v3-core `IACLManager.sol` (a00f28e), identical selectors.
interface IAaveV3ACLManager {
    /// @notice Adds a new address as FlashBorrower.
    function addFlashBorrower(
        address borrower
    ) external;

    /// @notice Returns true if the address is FlashBorrower, false otherwise.
    function isFlashBorrower(
        address borrower
    ) external view returns (bool);
}
