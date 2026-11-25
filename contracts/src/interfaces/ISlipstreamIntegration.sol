// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "./ILPVault.sol";

/// @title ISlipstreamIntegration
/// @notice The Aerodrome Slipstream LPVault: custody of unstaked positions of four position-manager generations.
/// @dev The generation is encoded in the high byte of `positionKey`. A staked NFT is owned by its gauge, so it fails
/// the pledge's owner check.
interface ISlipstreamIntegration is ILPVault {
    /// @notice An unknown generation, or a token ID of 2^248 or more.
    error UnsupportedNft();

    /// @notice Returns the number of position-manager and factory generations the LPVault accepts.
    function generationCount() external view returns (uint8 count);

    /// @notice Returns the position manager and factory of a generation; reverts `UnsupportedNft` for an unknown one.
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
}
