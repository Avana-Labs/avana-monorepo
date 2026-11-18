// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IMarketRegistryApprovals
/// @notice Approved CDP Spoke implementation code hashes and the recorded AMM protocol contracts of each integration.
/// @dev Each Spoke implementation deployment has its own code hash (immutables differ), so each is approved separately.
interface IMarketRegistryApprovals {
    event SpokeCodeHashApproved(bytes32 indexed codeHash);

    /// @param recordKey The record's key (chain, LPVault, its code hash, AMM protocol and pool keying).
    event IntegrationContractsRecorded(uint32 indexed integrationId, bytes32 indexed recordKey, address[] contracts);

    /// @notice The AMM protocol contracts of an integration were declared complete; its settlement routes can be set.
    event IntegrationContractsFinalized(uint32 indexed integrationId, bytes32 indexed recordKey, uint256 count);

    /// @notice The hash is 0, the hash of empty code, or already approved.
    error InvalidSpokeCodeHash(bytes32 codeHash);

    /// @notice Approves the code hash of a CDP Spoke implementation.
    /// @dev `APPLICATION_ADMIN` only. Approvals are never withdrawn.
    function approveSpokeCodeHash(
        bytes32 codeHash
    ) external;

    /// @notice Whether `codeHash` is an approved CDP Spoke implementation hash.
    /// @dev Includes `STANDARD_SPOKE_IMPLEMENTATION`'s hash. Never reverts.
    function isApprovedSpokeCodeHash(
        bytes32 codeHash
    ) external view returns (bool approved);

    /// @notice The implementation behind a recorded Spoke and whether it is still the one `deployCdpSpoke` approved.
    /// @dev Never reverts; zeros for an unknown Spoke or an unreadable slot.
    function spokeImplementationStatus(
        address spoke
    ) external view returns (address implementation, bytes32 codeHash, bool current);

    /// @notice Records AMM protocol contracts an integration's LPVault pins (position managers, factories).
    /// @dev `APPLICATION_ADMIN` only. After finalization, disables any active route that depends on an added address.
    function recordIntegrationContracts(
        uint32 integrationId,
        address[] calldata contracts
    ) external;

    /// @notice Finalizes an integration's AMM contract record; no route of its markets is accepted before.
    /// @dev `APPLICATION_ADMIN` only. Reverts `InvalidIntegration` if the record is empty, final or its key is stale.
    function finalizeIntegrationContracts(
        uint32 integrationId
    ) external;

    /// @notice The AMM protocol contracts recorded for an integration, in recording order.
    function integrationContracts(
        uint32 integrationId
    ) external view returns (address[] memory contracts);
}
