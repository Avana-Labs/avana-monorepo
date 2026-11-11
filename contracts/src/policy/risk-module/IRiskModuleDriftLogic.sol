// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DriftReason} from "../../types/DriftReason.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";

/// @title IRiskModuleDriftLogic
/// @notice Aave configuration drift, Hub shares == assets and the expected collateral factor (2.7 drift check).
interface IRiskModuleDriftLogic is IRiskModuleLogic {
    /// @notice First drift of the Spoke-wide checks and of `marketIds`; `(0, None)` when every check holds.
    /// @param spoke The CDP Spoke.
    /// @param marketIds Markets to check.
    /// @param proxy An account whose own dynamic key is checked too (pre-checks), or `address(0)`.
    /// @return marketId The drifting market, 0 for a Spoke-wide reason.
    /// @return reason The first reason found.
    /// @custom:spec REQ-ADAPTER-028, REQ-ADAPTER-029, REQ-ADAPTER-030, REQ-ADAPTER-031, REQ-ADAPTER-032, REQ-ADAPTER-033, REQ-ADAPTER-034, REQ-ADAPTER-035, REQ-ADAPTER-063, REQ-ADAPTER-064, REQ-RISK-063, REQ-RISK-069, REQ-RISK-088
    function driftOf(
        address spoke,
        uint256[] calldata marketIds,
        address proxy
    ) external view returns (uint256 marketId, DriftReason reason);

    /// @notice First drift of the Spoke-wide checks and of every Active or Offboarding market of the Spoke: the live
    /// `CONFIG_DRIFT` condition of every market of the Spoke.
    /// @param spoke The CDP Spoke.
    /// @return marketId The drifting market, 0 for a Spoke-wide reason.
    /// @return reason The first reason found, `None` when the Spoke's settings hold.
    /// @custom:spec REQ-RISK-078, REQ-RISK-090
    function spokeDrift(
        address spoke
    ) external view returns (uint256 marketId, DriftReason reason);

    /// @notice `homeHub.getAddedAssets(hubAssetId) == homeHub.getAddedShares(hubAssetId)` for the market.
    /// @param marketId The market.
    /// @return equal True when equal.
    /// @custom:spec REQ-ADAPTER-037
    function isHubSharesEqualAssets(
        uint256 marketId
    ) external view returns (bool equal);

    /// @notice SPEC-CF-001 collateral factor of the market, bps.
    /// @param marketId The market.
    /// @return cfBps The factor.
    /// @custom:spec SPEC-CF-001
    function expectedCollateralFactorBps(
        uint256 marketId
    ) external view returns (uint256 cfBps);
}
