// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IClIntegration} from "../IClIntegration.sol";

/// @title ISlipstreamIntegration
/// @notice The Aerodrome Slipstream LPVault: custody of unstaked Slipstream positions in exact-range markets.
/// @dev The NPM/factory generation is encoded in the high byte of `positionKey`.
interface ISlipstreamIntegration is IClIntegration {
    /// @notice Returns the number of NPM and factory generations the LPVault accepts.
    function generationCount() external view returns (uint8 count);

    /// @notice Returns the NPM and factory of a generation; reverts `InvalidPool` for an unknown one.
    function generation(
        uint8 index
    ) external view returns (address npm, address factory);

    /// @notice Returns the position key of an NFT of a generation.
    /// @dev Reverts `UnsupportedNft` for an unknown generation or `tokenId >= 2^248`.
    /// @return positionKey `bytes32((uint256(index) << 248) | tokenId)`.
    function positionKeyOf(
        uint8 index,
        uint256 tokenId
    ) external pure returns (bytes32 positionKey);

    /// @notice Returns whether an NFT of a market's generation is staked in the pool's gauge; false if a read fails.
    function isStaked(
        uint256 marketId,
        uint256 tokenId
    ) external view returns (bool staked);
}
