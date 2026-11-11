// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.28;

/// @title IAaveV3ACLManager
/// @notice Subset of the Aave V3 ACLManager interface for the `FLASH_BORROWER` role that the Aave V3 Pool reads to
/// waive the `flashLoan` premium. Declarations are copied from `contracts/interfaces/IACLManager.sol` of aave/aave-v3-core at commit
/// a00f28e3ad7c0e4a369d8e06e0ac9fd0acabcab7 with identical selectors.
/// @dev Called by: AaveV3FlashSource (`isFlashBorrower(address(this))` in `flashPremium`, the lookup the Pool makes in
/// `flashLoan`); the deployment configuration check and the mainnet-fork test fixtures read and grant the chain's flash
/// source (`IFlashSource` implementation) its `FLASH_BORROWER` role through it.
interface IAaveV3ACLManager {
    /// @notice Adds a new address as FlashBorrower. Source: `contracts/interfaces/IACLManager.sol`
    /// (aave-v3-core a00f28e).
    /// @dev Called by: mainnet-fork test fixtures, reproducing the Aave DAO listing payload.
    function addFlashBorrower(
        address borrower
    ) external;

    /// @notice Returns true if the address is FlashBorrower, false otherwise. Source:
    /// `contracts/interfaces/IACLManager.sol` (aave-v3-core a00f28e).
    /// @dev Called by: AaveV3FlashSource in `flashPremium`, the deployment configuration check and mainnet-fork tests.
    function isFlashBorrower(
        address borrower
    ) external view returns (bool);
}
