// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAaveV3PoolAddressesProvider
/// @notice Subset of the Aave V3 PoolAddressesProvider: the registry the Pool reads its ACLManager from.
/// @dev Copied from aave-v3-origin v3.4 `IPoolAddressesProvider.sol`, identical selectors.
interface IAaveV3PoolAddressesProvider {
    /// @notice Returns the address of the ACLManager.
    function getACLManager() external view returns (address);
}
