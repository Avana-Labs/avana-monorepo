// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAaveV3Pool
/// @notice Subset of the Aave V3 Pool that Avana's flash-loan helpers call (repay with collateral and the liquidation bot).
/// @dev Copied from aave-v3-origin v3.4 `IPool.sol`; only `flashLoan` waives the premium for a `FLASH_BORROWER`.
interface IAaveV3Pool {
    /// @notice Flash-borrows `amounts[i]` of `assets[i]` to `receiverAddress`, calls its `executeOperation`, then pulls
    /// back amount plus premium for every leg with `interestRateModes[i] == 0`.
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata interestRateModes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;

    /// @notice Returns the total flash-loan premium in bps of the borrowed amount (0 for a `FLASH_BORROWER`).
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);

    /// @notice Returns the packed configuration bitmap of a reserve (`ReserveConfigurationMap.data`): bit 56 active,
    /// bit 57 frozen, bit 60 paused, bit 63 flash-loan enabled.
    function getConfiguration(
        address asset
    ) external view returns (uint256 data);

    /// @notice Returns the reserve's virtual underlying balance: the liquidity the Pool accounts as lendable, which a
    /// direct transfer to the aToken does not raise (V3.1+ virtual accounting).
    function getVirtualUnderlyingBalance(
        address asset
    ) external view returns (uint128);

    /// @notice Returns the aToken of a reserve.
    function getReserveAToken(
        address asset
    ) external view returns (address);

    /// @notice Returns the PoolAddressesProvider.
    function ADDRESSES_PROVIDER() external view returns (address);
}
