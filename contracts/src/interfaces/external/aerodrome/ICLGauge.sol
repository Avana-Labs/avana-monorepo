// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ICLGauge
/// @notice Read-only subset of the Aerodrome Slipstream gauge, used only to detect staking.
/// @dev Copied from aerodrome-finance/slipstream `ICLGauge.sol`, identical selectors.
interface ICLGauge {
    /// @notice Returns the pool of the gauge.
    function pool() external view returns (address);

    /// @notice Returns the NPM of the gauge.
    function nft() external view returns (address);

    /// @notice Returns true when `depositor` has staked `tokenId`.
    function stakedContains(
        address depositor,
        uint256 tokenId
    ) external view returns (bool);
}
