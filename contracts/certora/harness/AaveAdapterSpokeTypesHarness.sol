// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4SpokePositionManagers} from "../../src/interfaces/external/aave/IAaveV4SpokePositionManagers.sol";

/// @title AaveAdapterSpokeTypesHarness
/// @notice Brings the Spoke's `SetUserPositionManagers` struct into the AaveAdapterGates scene, so the spec can name
/// `setUserPositionManagersWithSig` in a summary. It holds no state and is never called.
contract AaveAdapterSpokeTypesHarness {
    /// @notice Takes the struct so the compiler keeps its type in the scene.
    function noop(
        IAaveV4SpokePositionManagers.SetUserPositionManagers calldata
    ) external pure {}
}
