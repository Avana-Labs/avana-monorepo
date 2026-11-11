// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ICLGauge
/// @notice Read-only subset of the Aerodrome Slipstream gauge interface, copied from
/// `contracts/gauge/interfaces/ICLGauge.sol` of aerodrome-finance/slipstream `main` (read 2026-11-10), with identical selectors.
/// @dev Called by: the Slipstream LPVault and the Lens, only to detect staking. A staked NFT is owned by the gauge, so
/// `ownerOf(tokenId) == pool.gauge()` identifies it; Avana custodies unstaked NFTs only and never calls a gauge
/// mutator.
interface ICLGauge {
    /// @notice Returns the pool of the gauge. Source: `ICLGauge.sol`.
    function pool() external view returns (address);

    /// @notice Returns the NPM of the gauge. Source: `ICLGauge.sol`.
    function nft() external view returns (address);

    /// @notice Returns true when `depositor` has staked `tokenId`. Source: `ICLGauge.sol`.
    function stakedContains(
        address depositor,
        uint256 tokenId
    ) external view returns (bool);
}
