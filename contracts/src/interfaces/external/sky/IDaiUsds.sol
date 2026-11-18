// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.28;

/// @title IDaiUsds
/// @notice Subset of the Sky DAI/USDS converter that Avana swap routes call.
/// @dev Matches sky-ecosystem/usds `DaiUsds.sol` (d65551d), identical selectors.
interface IDaiUsds {
    /// @notice Converts `wad` USDS pulled from `msg.sender` into `wad` DAI sent to `usr`.
    function usdsToDai(
        address usr,
        uint256 wad
    ) external;

    /// @notice Returns the Dai token.
    function dai() external view returns (address);

    /// @notice Returns the USDS token.
    function usds() external view returns (address);
}
