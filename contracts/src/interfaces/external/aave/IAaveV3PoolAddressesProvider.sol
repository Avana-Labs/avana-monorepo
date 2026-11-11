// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAaveV3PoolAddressesProvider
/// @notice Subset of the Aave V3 PoolAddressesProvider interface: the registry the Pool reads its ACLManager from,
/// copied from `src/contracts/interfaces/IPoolAddressesProvider.sol` of aave-dao/aave-v3-origin (v3.4), with identical
/// selectors.
/// @dev Called by: AaveV3FlashSource in `flashPremium`, through `IAaveV3Pool.ADDRESSES_PROVIDER()`, so the source finds
/// the same ACLManager the Pool asks whether the borrower holds `FLASH_BORROWER`.
interface IAaveV3PoolAddressesProvider {
    /// @notice Returns the address of the ACLManager. Source: `IPoolAddressesProvider.sol`.
    /// @dev Called by: AaveV3FlashSource in `flashPremium`.
    function getACLManager() external view returns (address);
}
