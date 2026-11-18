// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {HubAssetView} from "./types/LensTypes.sol";

/// @title ILensHubAssets
/// @notice One Hub asset's totals, liquidity, rates, USD price and allocation by Spoke.
interface ILensHubAssets {
    /// @notice Returns one asset of a Hub with one slice per Spoke registered on it.
    /// @dev Reverts with `UnknownHubAsset` when the Hub lists no such asset.
    function getHubAsset(
        address hub,
        uint256 assetId
    ) external view returns (HubAssetView memory asset);
}
