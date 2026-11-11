// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAaveV3Pool
/// @notice Subset of the Aave V3 Pool interface that the chain's `IFlashSource` implementation calls, copied from
/// `src/contracts/interfaces/IPool.sol` of aave-dao/aave-v3-origin (v3.4), with identical selectors.
/// @dev Called by: the AaveV3FlashSource of each chain (Ethereum Core Pool `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2`,
/// Base Pool `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5`). Avana uses `flashLoan` with one asset and
/// `interestRateModes = [0]`, never `flashLoanSimple`: only `flashLoan` waives the premium for an address holding the
/// ACLManager `FLASH_BORROWER` role. The Pool checks per asset that the reserve is active, not paused and flash-loan
/// enabled, and that `aToken.totalSupply() >= amount`; a frozen reserve can still be flash-loaned. The loan lowers the
/// reserve's virtual underlying balance with checked arithmetic, so the real ceiling is the smaller of the aToken's
/// underlying balance and that virtual balance. The Pool pulls `amount + premium` from the receiver with `transferFrom`
/// after `executeOperation` returns.
interface IAaveV3Pool {
    /// @notice Flash-borrows `amounts[i]` of `assets[i]` to `receiverAddress`, calls its `executeOperation`, then pulls
    /// back amount plus premium for every leg with `interestRateModes[i] == 0`. Source: `IPool.sol`.
    /// @dev Called by: AaveV3FlashSource, with single-element arrays and mode 0.
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
    /// Source: `IPool.sol`.
    /// @dev Called by: AaveV3FlashSource before every loan, to check the premium against `maxFlashFeeBps`.
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);

    /// @notice Returns the packed configuration bitmap of a reserve (`ReserveConfigurationMap.data`): bit 56 active,
    /// bit 57 frozen, bit 60 paused, bit 63 flash-loan enabled. Source: `IPool.sol`.
    /// @dev Called by: AaveV3FlashSource in `maxFlashLoan`.
    function getConfiguration(
        address asset
    ) external view returns (uint256 data);

    /// @notice Returns the reserve's virtual underlying balance: the liquidity the Pool accounts as lendable, which a
    /// direct transfer to the aToken does not raise (V3.1+ virtual accounting). Source: `IPool.sol`.
    /// @dev Called by: AaveV3FlashSource in `maxFlashLoan` (available = min(aToken balance, virtual balance)).
    function getVirtualUnderlyingBalance(
        address asset
    ) external view returns (uint128);

    /// @notice Returns the aToken of a reserve. Source: `IPool.sol`.
    /// @dev Called by: AaveV3FlashSource in `maxFlashLoan` (idle liquidity = asset balance of the aToken).
    function getReserveAToken(
        address asset
    ) external view returns (address);

    /// @notice Returns the PoolAddressesProvider. Source: `IPool.sol`.
    /// @dev Called by: AaveV3FlashSource in `flashPremium` (to find the ACLManager) and the deployment configuration
    /// check.
    function ADDRESSES_PROVIDER() external view returns (address);
}
