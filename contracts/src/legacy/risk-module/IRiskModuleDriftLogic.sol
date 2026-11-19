// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DriftReason} from "../../types/MarketTypes.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";

/// @title IRiskModuleDriftLogic
/// @notice Aave configuration drift, Hub shares == assets and the expected collateral factor.
interface IRiskModuleDriftLogic is IRiskModuleLogic {
    /// @notice First drift of the Spoke-wide checks and of `marketIds`; `(0, None)` when every check holds.
    /// @param proxy An account whose own dynamic key is checked too (pre-checks), or `address(0)`.
    /// @return marketId The drifting market, 0 for a Spoke-wide reason.
    function driftOf(
        address spoke,
        uint256[] calldata marketIds,
        address proxy
    ) external view returns (uint256 marketId, DriftReason reason);

    /// @notice First drift of the Spoke-wide checks and of every Active or Offboarding market of the Spoke.
    /// @return marketId The drifting market, 0 for a Spoke-wide reason.
    function spokeDrift(
        address spoke
    ) external view returns (uint256 marketId, DriftReason reason);

    /// @notice `homeHub.getAddedAssets(hubAssetId) == homeHub.getAddedShares(hubAssetId)` for the market.
    function isHubSharesEqualAssets(
        uint256 marketId
    ) external view returns (bool equal);

    /// @notice Expected collateral factor of the market, bps.
    function expectedCollateralFactorBps(
        uint256 marketId
    ) external view returns (uint256 cfBps);
}
