// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAaveV4SpokePositionManagers
/// @notice The position-manager surface of the pinned Aave V4 Spoke (a3ef63e), ABI-equal. Avana never calls it: the
/// AaveAdapter's fixed selector set (REQ-PROXY-008) excludes every function here, which its selector-allowlist test and
/// the Certora rule `noPositionManagerApproval` check.
interface IAaveV4SpokePositionManagers {
    /// @notice One approval change of a signed batch.
    struct PositionManagerUpdate {
        // The position manager.
        address positionManager;
        // True to approve, false to revoke.
        bool approve;
    }

    /// @notice A signed batch of approval changes for one user.
    struct SetUserPositionManagers {
        // The user the batch acts for.
        address onBehalfOf;
        // The approval changes.
        PositionManagerUpdate[] updates;
        // The user's intent nonce.
        uint256 nonce;
        // Last valid timestamp.
        uint256 deadline;
    }

    /// @notice Approves or revokes `positionManager` for the caller's own account.
    function setUserPositionManager(
        address positionManager,
        bool approve
    ) external;

    /// @notice Applies a batch of approval changes signed by `params.onBehalfOf`.
    function setUserPositionManagersWithSig(
        SetUserPositionManagers calldata params,
        bytes calldata signature
    ) external;

    /// @notice Lets a position manager drop its own approval for `onBehalfOf`.
    function renouncePositionManagerRole(
        address onBehalfOf
    ) external;

    /// @notice Runs several Spoke calls as the caller.
    function multicall(
        bytes[] calldata data
    ) external returns (bytes[] memory);
}
