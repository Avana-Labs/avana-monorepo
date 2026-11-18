// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DriftReason} from "../../types/DriftReason.sol";

/// @title IMarketRegistryDriftLogic
/// @notice The per-market reads of `spokeSettingsDrift`, served by the MarketRegistry's activation logic contract.
/// @dev Reads no registry storage; the registry calls it directly. Never reverts on an Aave read.
interface IMarketRegistryDriftLogic {
    /// @notice Drift of one market's collateral reserve.
    /// @dev A failed read reports `ReserveIdentity`.
    /// @return reason The first drift found, or `None`.
    function marketDrift(
        address spoke,
        address homeHub,
        address vaultToken,
        uint256 reserveId,
        uint256 hubAssetId
    ) external view returns (DriftReason reason);
}
