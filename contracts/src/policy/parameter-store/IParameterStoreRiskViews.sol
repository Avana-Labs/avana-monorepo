// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtReserveParams} from "./types/DebtReserveParams.sol";

/// @title IParameterStoreRiskViews
/// @notice Exposure caps, the stress floor, `minPledgeUsd`, debt-reserve buy slippage, route depth thresholds
/// and the implementation immutables of the ParameterStore.
/// @dev Every view is `view` and never reverts; an unknown key returns 0.
interface IParameterStoreRiskViews {
    /// @notice Regular pledge budget of a market.
    /// @param marketId Market identifier.
    /// @return value 8-decimal USD.
    /// @custom:spec SPEC-CAP-002, REQ-RISK-041
    function marketUsdCap(
        uint256 marketId
    ) external view returns (uint256 value);

    /// @notice Rescue top-up budget of a market.
    /// @param marketId Market identifier.
    /// @return value 8-decimal USD.
    /// @custom:spec SPEC-CAP-002, SPEC-CAP-003
    function topUpSliceUsd(
        uint256 marketId
    ) external view returns (uint256 value);

    /// @notice Stress floor of a market.
    /// @param marketId Market identifier.
    /// @return value 8-decimal USD per whole vault token.
    /// @custom:spec SPEC-CAP-001, REQ-RISK-045
    function stressFloorUsd(
        uint256 marketId
    ) external view returns (uint256 value);

    /// @notice Aggregate exposure cap of an underlying token across every market of a Hub on the chain.
    /// @param hub The Hub the cap is keyed by; every CDP Spoke and market of that Hub on the chain shares it.
    /// @param token Underlying pool token.
    /// @return value 8-decimal USD.
    /// @custom:spec SPEC-CAP-002, REQ-PSTORE-026
    function tokenUsdCap(
        address hub,
        address token
    ) external view returns (uint256 value);

    /// @notice Exposure cap per depositor wallet across every market of a Hub on the chain.
    /// @param hub The Hub the cap is keyed by; every CDP Spoke and market of that Hub on the chain shares it.
    /// @return value 8-decimal USD.
    /// @custom:spec SPEC-CAP-002, REQ-PSTORE-026
    function depositorUsdCap(
        address hub
    ) external view returns (uint256 value);

    /// @notice Maximum Avana share of a pool's harmonic-mean liquidity: the pool-share cap and the concentration gate.
    /// @dev Default 10,000 bps (off, Q-403); per-pool cap optional: `tightenPoolShareMaxBpsOf` sets one and checks
    /// read `poolShareMaxBpsOf(poolKey)`. Replaces the former separate pool-share breaker threshold (Q-399).
    /// @return value bps.
    /// @custom:spec SPEC-CAP-005, SPEC-BRK-002, Q-399
    function poolShareMaxBps() external view returns (uint16 value);

    /// @notice Minimum value of one pledge into a market; the RiskModule reverts `BelowMinPledge` below it.
    /// @param marketId Market identifier.
    /// @return value 8-decimal USD.
    /// @custom:spec REQ-PSTORE-005, Q-230
    function minPledgeUsd(
        uint256 marketId
    ) external view returns (uint256 value);

    /// @notice Settlement parameters of one debt asset.
    /// @param asset Debt asset.
    /// @return p Rounding allowance, base units of `asset` (zeros for an unknown asset).
    /// @custom:spec REQ-PSTORE-006, Q-380
    function debtAssetParams(
        address asset
    ) external view returns (DebtReserveParams memory p);

    /// @notice Depth threshold of a swap-route slot: the smallest input the route must absorb within the market's
    /// slippage allowance for the slot to count as usable at activation and in the liveness check.
    /// @param marketId Market identifier.
    /// @param token Pool token sold.
    /// @param debtAsset Debt asset bought.
    /// @param kind 0 primary, 1 backup.
    /// @return value Base units of `debtAsset` (0 for an unknown slot).
    /// @custom:spec REQ-CONFIG-070, REQ-PSTORE-007, Q-379
    function routeDepthThreshold(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind
    ) external view returns (uint256 value);

    /// @notice MarketRegistry fixed proxy address (implementation immutable).
    /// @return registry Address.
    /// @custom:spec REQ-PSTORE-001
    function MARKET_REGISTRY() external view returns (address registry);

    /// @notice Pool-share cap of one pool: the pool's override when one is set, otherwise `poolShareMaxBps()`.
    /// @dev A risk provider sets the override at listing or later through `tightenPoolShareMaxBpsOf`. The result is
    /// never above the chain default: an override above a later-lowered default reads as the default. The RiskModule's
    /// pool-share check and concentration gate read this value. Default 10,000 bps (off); per-pool cap optional. E.g.:
    /// default 10,000 and override 1,000 returns 1,000; no override returns 10,000; default lowered to 500 returns 500.
    /// @param poolKey `keccak256(abi.encode(integrationId, pool, poolId))`, as in `poolUnits(poolKey)`.
    /// @return value bps.
    /// @custom:spec SPEC-CAP-005, SPEC-BRK-002, Q-383, Q-399
    function poolShareMaxBpsOf(
        bytes32 poolKey
    ) external view returns (uint16 value);
}
