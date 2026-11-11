// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DriftReason} from "../../types/DriftReason.sol";

/// @title IMarketRegistryDriftLogic
/// @notice The per-market reads of `spokeSettingsDrift`, served by the MarketRegistry's activation logic contract.
/// @dev Reads no registry storage, only the Aave Spoke and Hub named in its arguments, so the registry calls it
/// directly from its drift view instead of carrying the reads in its own code. Never reverts on an Aave read.
/// @custom:spec REQ-CONFIG-076, REQ-ADAPTER-028, REQ-ADAPTER-029, REQ-ADAPTER-030
interface IMarketRegistryDriftLogic {
    /// @notice Drift of one market's collateral reserve.
    /// @dev `HomeHubMismatch` when the reserve's Hub is not `homeHub`; `ReserveIdentity` when its underlying is not
    /// `vaultToken`, its Hub asset ID is not `hubAssetId` or any read fails; `ReceiveSharesOn`, `LiquidationFeeNonZero`
    /// (on the reserve's latest dynamic key) and `ReinvestmentController` (on the Hub asset) for the three standard-Spoke
    /// settings; `None` otherwise.
    /// @param spoke The CDP Spoke.
    /// @param homeHub The Spoke's recorded home Hub.
    /// @param vaultToken The market's vault token.
    /// @param reserveId The market's reserve on the Spoke.
    /// @param hubAssetId The market's Hub asset ID.
    /// @return reason The first drift found, or `None`.
    /// @custom:spec REQ-CONFIG-076
    function marketDrift(
        address spoke,
        address homeHub,
        address vaultToken,
        uint256 reserveId,
        uint256 hubAssetId
    ) external view returns (DriftReason reason);
}
