// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.28;

/// @title ILitePsm
/// @notice Subset of the Sky LitePSM (`DssLitePsm`) interface that Avana swap routes call on LitePSM USDC.
/// Declarations match `src/DssLitePsm.sol` of sky-ecosystem/dss-lite-psm at commit
/// dbf0022225f645f5697e5517d0cf00810471bccf, with identical selectors.
/// @dev Called by: swap routes that convert DAI or USDS to USDC through the LitePSM.
interface ILitePsm {
    /// @notice Swaps Dai into `gem`, pulling the Dai cost from `msg.sender`; the call reverts while `tout` is set to
    /// `HALTED`. Source: `src/DssLitePsm.sol` (dss-lite-psm dbf0022).
    /// @dev Called by: swap routes that convert DAI or USDS to USDC through the LitePSM.
    /// @param usr The destination of the bought gems.
    /// @param gemAmt The amount of gem to buy, in `gem` precision.
    /// @return daiInWad The amount of Dai required to sell.
    function buyGem(
        address usr,
        uint256 gemAmt
    ) external returns (uint256 daiInWad);

    /// @notice Returns the fee for buying gems, in WAD (1e18 is a 100% fee); `type(uint256).max` halts buying. The
    /// source declares it as `uint256 public tout`. Source: `src/DssLitePsm.sol` (dss-lite-psm dbf0022).
    /// @dev Called by: swap routes that convert DAI or USDS to USDC through the LitePSM, to size `gemAmt`.
    function tout() external view returns (uint256);

    /// @notice Returns the gem the LitePSM sells. The source declares it as `GemLike public immutable gem`. Source:
    /// `src/DssLitePsm.sol` (dss-lite-psm dbf0022).
    /// @dev Called by: swap routes, in the constructor, to check the gem is the route's output token.
    function gem() external view returns (address);

    /// @notice Returns the Dai the LitePSM takes. The source declares it as `DaiLike public immutable dai`. Source:
    /// `src/DssLitePsm.sol` (dss-lite-psm dbf0022).
    /// @dev Called by: swap routes, in the constructor, to check the Dai the route spends.
    function dai() external view returns (address);

    /// @notice Returns `10^(18 - gem.decimals())`. The source declares it as `uint256 public immutable
    /// to18ConversionFactor`. Source: `src/DssLitePsm.sol` (dss-lite-psm dbf0022).
    /// @dev Called by: swap routes, in the constructor, to check the conversion factor the route sizes `gemAmt` with.
    function to18ConversionFactor() external view returns (uint256);
}
