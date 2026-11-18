// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtReserveParams} from "./types/DebtReserveParams.sol";

/// @title IParameterStoreRiskViews
/// @notice Exposure caps, stress floor, minimum pledge, route depth thresholds and registry address.
interface IParameterStoreRiskViews {
    /// @notice Regular pledge budget of a market.
    /// @return value 8-decimal USD.
    function marketUsdCap(
        uint256 marketId
    ) external view returns (uint256 value);

    /// @notice Rescue top-up budget of a market.
    /// @return value 8-decimal USD.
    function topUpSliceUsd(
        uint256 marketId
    ) external view returns (uint256 value);

    /// @notice Stress floor of a market.
    /// @return value 8-decimal USD per whole vault token.
    function stressFloorUsd(
        uint256 marketId
    ) external view returns (uint256 value);

    /// @notice Aggregate exposure cap of an underlying token across every market of a Hub on the chain.
    /// @return value 8-decimal USD.
    function tokenUsdCap(
        address hub,
        address token
    ) external view returns (uint256 value);

    /// @notice Chain default of the maximum Avana share of a pool's liquidity; 10,000 bps means off.
    function poolShareMaxBps() external view returns (uint16 value);

    /// @notice Minimum value of one pledge into a market; the RiskModule reverts `BelowMinPledge` below it.
    /// @return value 8-decimal USD.
    function minPledgeUsd(
        uint256 marketId
    ) external view returns (uint256 value);

    /// @notice Settlement parameters of one debt asset.
    /// @return p Rounding allowance, base units of `asset` (zeros for an unknown asset).
    function debtAssetParams(
        address asset
    ) external view returns (DebtReserveParams memory p);

    /// @notice Smallest input a swap-route slot must absorb within the slippage allowance to count as usable.
    /// @param token Pool token sold.
    /// @param debtAsset Debt asset bought.
    /// @param kind 0 primary, 1 backup.
    /// @return value Base units of `debtAsset` (0 for an unknown slot).
    function routeDepthThreshold(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind
    ) external view returns (uint256 value);

    /// @notice MarketRegistry fixed proxy address (implementation immutable).
    function MARKET_REGISTRY() external view returns (address registry);

    /// @notice Pool-share cap of one pool: the pool's override when one is set, otherwise `poolShareMaxBps()`.
    /// @dev Never above the chain default.
    /// @param poolKey `keccak256(abi.encode(integrationId, pool, poolId))`, as in `poolUnits(poolKey)`.
    function poolShareMaxBpsOf(
        bytes32 poolKey
    ) external view returns (uint16 value);
}
