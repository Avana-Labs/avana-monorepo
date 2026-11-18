// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.28;

/// @title ILitePsm
/// @notice Subset of the Sky LitePSM (`DssLitePsm`) that Avana swap routes call.
/// @dev Matches sky-ecosystem/dss-lite-psm `DssLitePsm.sol` (dbf0022), identical selectors.
interface ILitePsm {
    /// @notice Swaps Dai into `gem`, pulling the Dai cost from `msg.sender`; the call reverts while `tout` is set to
    /// `HALTED`.
    /// @param usr The destination of the bought gems.
    /// @param gemAmt The amount of gem to buy, in `gem` precision.
    /// @return daiInWad The amount of Dai required to sell.
    function buyGem(
        address usr,
        uint256 gemAmt
    ) external returns (uint256 daiInWad);

    /// @notice Returns the fee for buying gems, in WAD (1e18 is a 100% fee); `type(uint256).max` halts buying.
    function tout() external view returns (uint256);

    /// @notice Returns the gem the LitePSM sells.
    function gem() external view returns (address);

    /// @notice Returns the Dai the LitePSM takes.
    function dai() external view returns (address);

    /// @notice Returns `10^(18 - gem.decimals())`.
    function to18ConversionFactor() external view returns (uint256);
}
