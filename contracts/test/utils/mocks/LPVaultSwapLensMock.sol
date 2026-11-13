// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The LPVaultSwap views the Lens reads, as spec 2.11 defines them: the committed-operator registry
/// (`isApprovedKeeper`, `approvedKeeperCount`, and `activeKeeperCount`, the registered operators whose address is not
/// frozen). The lead swaps in the real LPVaultSwap after the merge.
contract LPVaultSwapLensMock {
    mapping(address => bool) public isApprovedKeeper;
    uint256 public approvedKeeperCount;
    uint256 public activeKeeperCount;

    function setKeeper(
        address keeper,
        bool approved,
        bool frozen
    ) external {
        if (approved && !isApprovedKeeper[keeper]) {
            ++approvedKeeperCount;
            if (!frozen) ++activeKeeperCount;
        }
        isApprovedKeeper[keeper] = approved;
    }
}
