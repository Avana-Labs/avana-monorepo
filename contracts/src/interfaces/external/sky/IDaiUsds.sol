// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.28;

/// @title IDaiUsds
/// @notice Subset of the Sky DAI/USDS converter interface that Avana swap routes call. Declarations match
/// `src/DaiUsds.sol` of sky-ecosystem/usds at commit d65551dbc11cfe1afcc4718ab790663b99d766af, with identical
/// selectors.
/// @dev Called by: swap routes that convert USDS to DAI before the LitePSM.
interface IDaiUsds {
    /// @notice Converts `wad` USDS pulled from `msg.sender` into `wad` DAI sent to `usr`. Source: `src/DaiUsds.sol`
    /// (usds d65551d).
    /// @dev Called by: swap routes that convert USDS to DAI before the LitePSM.
    function usdsToDai(
        address usr,
        uint256 wad
    ) external;

    /// @notice Returns the Dai token. The source declares it as `DaiLike public immutable dai`. Source:
    /// `src/DaiUsds.sol` (usds d65551d).
    /// @dev Called by: swap routes, in the constructor, to check the converter's tokens.
    function dai() external view returns (address);

    /// @notice Returns the USDS token. The source declares it as `UsdsLike public immutable usds`. Source:
    /// `src/DaiUsds.sol` (usds d65551d).
    /// @dev Called by: swap routes, in the constructor, to check the converter's tokens.
    function usds() external view returns (address);
}
