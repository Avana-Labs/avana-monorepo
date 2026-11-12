// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IMarketRegistryApprovals
/// @notice The approved code hashes of CDP Spoke implementations, the implementation check that binds each recorded
/// Spoke to the code actually behind its proxy, and the AMM protocol contracts of each integration.
/// @dev An Aave V4 Spoke is a TransparentUpgradeableProxy whose implementation keeps `ORACLE`,
/// `MAX_USER_RESERVES_LIMIT` and its EIP-712 domain cache (its own address and the chain ID) as immutables, so every
/// implementation deployment, an upgrade of the same code included, has its own code hash. Governance approves each
/// hash at the normal delay after the listing package shows that the code is the audited `SpokeInstance` with only
/// those immutables differing; `STANDARD_SPOKE_IMPLEMENTATION`'s hash is approved from
/// deployment. `deployCdpSpoke` reads the implementation from the proxy's ERC-1967 slot (through `extSload`, which
/// runs in the proxy's storage), never from the proxy's own code, and records its code hash. An Aave DAO upgrade of
/// the Spoke changes that slot, so `spokeImplementationStatus` reports it until `deployCdpSpoke` re-approves the
/// Spoke with an approved hash. The read trusts the approved implementation's `extSload`; a replacement written to
/// hide itself would be an Aave governance compromise, which monitoring of the proxy's `Upgraded` event covers.
/// @custom:spec REQ-CONFIG-074, REQ-CONFIG-016, REQ-MREG-020, REQ-MREG-035, REQ-CONFIG-040, REQ-RISK-088, Q-309
interface IMarketRegistryApprovals {
    /// @notice A Spoke implementation code hash was approved.
    /// @param codeHash The approved hash.
    /// @custom:spec REQ-CONFIG-074
    event SpokeCodeHashApproved(bytes32 indexed codeHash);

    /// @notice AMM protocol contracts of an integration were recorded.
    /// @param integrationId The integration.
    /// @param recordKey The record's key: `keccak256(abi.encode(chainid, lpVault, lpVault.codehash, AMM_PROTOCOL(),
    /// poolKeying))` (REQ-MREG-035).
    /// @param contracts The contracts added.
    /// @custom:spec REQ-MREG-020, REQ-MREG-035, REQ-CONFIG-040
    event IntegrationContractsRecorded(uint32 indexed integrationId, bytes32 indexed recordKey, address[] contracts);

    /// @notice The AMM protocol contracts of an integration were declared complete; its settlement routes can be set.
    /// @param integrationId The integration.
    /// @param recordKey The record's key (REQ-MREG-035).
    /// @param count How many contracts the record holds.
    /// @custom:spec REQ-MREG-035, REQ-CONFIG-040
    event IntegrationContractsFinalized(uint32 indexed integrationId, bytes32 indexed recordKey, uint256 count);

    /// @notice The hash is 0, the hash of empty code, or already approved.
    /// @param codeHash The refused hash.
    /// @custom:spec REQ-CONFIG-074
    error InvalidSpokeCodeHash(bytes32 codeHash);

    /// @notice Approves the code hash of a CDP Spoke implementation.
    /// @dev `APPLICATION_ADMIN`, normal delay. Reverts `InvalidSpokeCodeHash` for 0, the empty-code hash or a hash
    /// already approved (the hash of `STANDARD_SPOKE_IMPLEMENTATION` included). Approvals are never withdrawn: a Spoke
    /// stops being current only when its implementation changes. Emits `SpokeCodeHashApproved`.
    /// Example: a second Stable CDP Spoke built from the same `SpokeInstance` code with its own AaveOracle has another
    /// hash; the batch that records it runs `approveSpokeCodeHash(h2)` and then `deployCdpSpoke`, and so does the batch
    /// that re-approves a Spoke after an Aave DAO upgrade.
    /// @param codeHash `EXTCODEHASH` of the implementation.
    /// @custom:spec REQ-CONFIG-074
    function approveSpokeCodeHash(
        bytes32 codeHash
    ) external;

    /// @notice Whether `codeHash` is an approved CDP Spoke implementation hash.
    /// @dev True for `STANDARD_SPOKE_IMPLEMENTATION`'s hash and every hash added by `approveSpokeCodeHash`; false for 0
    /// and the empty-code hash. Never reverts.
    /// @param codeHash The hash.
    /// @return approved True when approved.
    /// @custom:spec REQ-CONFIG-074
    function isApprovedSpokeCodeHash(
        bytes32 codeHash
    ) external view returns (bool approved);

    /// @notice The implementation behind a recorded Spoke and whether it is still the one `deployCdpSpoke` approved.
    /// @dev Never reverts. `implementation` is the address in the Spoke proxy's ERC-1967 implementation slot and
    /// `codeHash` its code hash, all three results zero or false for a Spoke that is not recorded or whose slot cannot be
    /// read. `current` is true only when the Spoke is approved,
    /// the slot holds the recorded implementation and its code hash equals the hash recorded at approval; anything
    /// else (an Aave DAO upgrade, an unreadable slot, an unknown Spoke) is false and needs a re-approval by
    /// `deployCdpSpoke`. The RiskModule's drift check reads it and reports `DriftReason.SpokeImplementation` when
    /// `current` is false; `spokeSettingsDrift` reports the same.
    /// @param spoke The CDP Spoke.
    /// @return implementation The implementation in force.
    /// @return codeHash Its code hash.
    /// @return current True when it is the approved implementation.
    /// @custom:spec REQ-CONFIG-074, REQ-CONFIG-016, REQ-RISK-088
    function spokeImplementationStatus(
        address spoke
    ) external view returns (address implementation, bytes32 codeHash, bool current);

    /// @notice Records AMM protocol contracts an integration's LPVault pins: its position managers, factories, or the
    /// singleton of a protocol keyed by pool identifier.
    /// @dev `APPLICATION_ADMIN`, normal delay. Reverts `InvalidIntegration(integrationId)` for an unregistered
    /// integration, an empty list or one of more than 16 addresses, an address that is 0, has no code or is already
    /// recorded for the integration, and when the integration's record key (chain, LPVault address, LPVault code hash,
    /// AMM protocol tag and pool keying) differs from the key written by the first call (REQ-MREG-035).
    /// Adds each address to the protected set of the address freeze at once (REQ-MREG-020); no route depending on any
    /// of them is accepted (REQ-CONFIG-040). Once the record is finalized, an addition also re-checks every route slot
    /// set for the integration's markets that are not Cancelled or Closed: an active route whose `dependencies()` names
    /// an added address, or cannot be read, is disabled and emits `RouteDisabled`, so a newly protected address leaves
    /// no approved unsafe route usable. Records are never removed. Emits `IntegrationContractsRecorded`. Example:
    /// Uniswap v3 records its NonfungiblePositionManager and factory; Slipstream records the four NPM and factory
    /// generations.
    /// @param integrationId The registered integration.
    /// @param contracts The contracts to add.
    /// @custom:spec REQ-MREG-020, REQ-MREG-035, REQ-CONFIG-040
    function recordIntegrationContracts(
        uint32 integrationId,
        address[] calldata contracts
    ) external;

    /// @notice Declares an integration's record of AMM protocol contracts complete; until then no settlement route of
    /// any of the integration's markets is accepted.
    /// @dev `APPLICATION_ADMIN`, normal delay. Reverts `InvalidIntegration(integrationId)` for an unregistered
    /// integration, an empty record, a record already finalized, or a record whose key no longer matches the
    /// integration (another chain, or another LPVault code). Emits `IntegrationContractsFinalized` (REQ-MREG-035).
    /// @param integrationId The registered integration.
    /// @custom:spec REQ-MREG-035, REQ-CONFIG-040
    function finalizeIntegrationContracts(
        uint32 integrationId
    ) external;

    /// @notice The AMM protocol contracts recorded for an integration, in recording order.
    /// @param integrationId The integration.
    /// @return contracts The recorded contracts (empty when none).
    /// @custom:spec REQ-MREG-020
    function integrationContracts(
        uint32 integrationId
    ) external view returns (address[] memory contracts);
}
