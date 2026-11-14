// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {HubAssetExposureView} from "./types/HubAssetExposureView.sol";
import {TailCoverageView} from "./types/TailCoverageView.sol";

/// @title ILensRisk
/// @notice Risk views of the Lens: circuit-breaker status of markets and debt reserves, address freezes, and the tail
/// coverage of each debt asset's First-Loss Reserve.
interface ILensRisk {
    /// @notice Returns a market's circuit-breaker status, passed through from the RiskModule.
    /// @dev `reasons` ORs the conditions true in this block, the temporary gates still inside `gateRecoverySeconds`
    /// of their last recorded breach and the latched security freezes (`BreakerReasons` bits, Q-399).
    /// A tripped breaker blocks only new activity, never repay, debt-free exits, rescue top-ups or liquidation.
    /// @param marketId MarketRegistry market identifier.
    /// @return reasons Breaker reason bitmap.
    /// @return reopensAt When the last temporary gate reopens; 0 when none. A security freeze needs a reset.
    /// @custom:spec REQ-LENS-037, Q-241, Q-244
    function getBreakerStatus(
        uint256 marketId
    ) external view returns (uint32 reasons, uint64 reopensAt);

    /// @notice Returns a debt reserve's circuit-breaker status, passed through from the RiskModule.
    /// @param spoke The CDP Spoke.
    /// @param debtReserveId The debt reserve.
    /// @return reasons Breaker reason bitmap (condition, recovering and latched).
    /// @return reopensAt When the last temporary gate reopens; 0 when none. A security freeze needs a reset.
    /// @custom:spec REQ-LENS-037, Q-241, Q-244
    function getDebtBreakerStatus(
        address spoke,
        uint256 debtReserveId
    ) external view returns (uint32 reasons, uint64 reopensAt);

    /// @notice Returns whether an address is frozen in the MarketRegistry.
    /// @param account The address.
    /// @return frozen `MARKET_REGISTRY.isFrozenAddress(account)`.
    /// @custom:spec REQ-LENS-037, Q-242
    function isFrozenAddress(
        address account
    ) external view returns (bool frozen);

    /// @notice Returns the funded First-Loss Reserve of a (funding Hub, debt asset) pair against its largest one-token
    /// tail exposure.
    /// @dev Loops over the MarketRegistry's Spokes, their approved debt reserves and its markets. Reverts with
    /// `UnknownDebtAsset(debtAsset)` when no approved debt reserve of any CDP Spoke draws the asset from `hub`. Rounding
    /// never overstates coverage.
    /// @param hub The funding Hub.
    /// @param debtAsset The debt asset.
    /// @return coverage Funded balance, minimum, worst token, tail exposure and coverage ratio.
    /// @custom:spec REQ-LENS-034, REQ-LENS-039, SPEC-CAP-008, Q-249
    function getTailCoverage(
        address hub,
        address debtAsset
    ) external view returns (TailCoverageView memory coverage);

    /// @notice Deficit of `(hub, asset)` recorded by the Hub above what its two loss layers hold (the First-Loss Reserve and
    /// the DAO deficit offset, every listed Spoke whose `FIRST_LOSS_LAYER()` is that First-Loss Reserve), base units.
    /// @param hub The Hub.
    /// @param asset The asset.
    /// @return uncovered `max(0, deficit - fundedBalance - offsetFunded)`.
    /// @custom:spec REQ-LENS-042, REQ-FLR-046
    function uncoveredDeficit(
        address hub,
        address asset
    ) external view returns (uint256 uncovered);

    /// @notice Exposure of `(hub, asset)` across every Spoke drawing on it, with its coverage check.
    /// @param hub The Hub.
    /// @param asset The asset.
    /// @return view_ The exposure report.
    /// @custom:spec REQ-LENS-043
    function getHubAssetExposure(
        address hub,
        address asset
    ) external view returns (HubAssetExposureView memory view_);
}
