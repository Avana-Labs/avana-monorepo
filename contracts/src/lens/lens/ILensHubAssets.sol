// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {HubAssetView} from "./types/HubAssetView.sol";

/// @title ILensHubAssets
/// @notice One Hub asset for the Lend pages: totals, available liquidity, rates, rate curve, the asset's one USD price
/// and its allocation by Spoke.
interface ILensHubAssets {
    /// @notice Returns one asset of a Hub with one slice per Spoke registered on it.
    /// @dev Reverts with `UnknownHubAsset` when the Hub lists no such asset.
    /// @param hub The Hub.
    /// @param assetId The Hub's asset identifier.
    /// @return asset The view.
    /// @custom:spec REQ-LENS-058, REQ-LENS-059
    function getHubAsset(
        address hub,
        uint256 assetId
    ) external view returns (HubAssetView memory asset);
}
