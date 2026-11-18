// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IParameterStoreTighten
/// @notice Tighten setters of the ParameterStore: each moves one risk parameter in its safer direction.
/// @dev Tighten role: the governance Safe after 12 hours, the risk steward at once.
interface IParameterStoreTighten {
    /// @notice Lowers a market's `slippageAllowanceBps`.
    /// @dev Reverts `LivenessBound` below `slippageAllowanceMinBps`.
    function tightenSlippageAllowanceBps(
        uint256 marketId,
        uint16 value
    ) external;

    /// @notice Lowers a debt asset's `floorRoundingAllowance`.
    /// @param value New allowance, base units of `asset`.
    function tightenFloorRoundingAllowance(
        address asset,
        uint256 value
    ) external;

    /// @notice Lowers a feed's `borrowPriceMaxAge`.
    /// @dev Affects borrowing only, never liquidation.
    /// @param value New age limit, seconds.
    function tightenBorrowPriceMaxAge(
        address feed,
        uint32 value
    ) external;

    /// @notice Lowers a market's `poolRiskFactor`, to mirror an Aave collateral-factor cut.
    /// @param value New factor, bps.
    function tightenPoolRiskFactor(
        uint256 marketId,
        uint16 value
    ) external;

    /// @notice Raises a swap-route slot's depth threshold.
    /// @dev A monitoring and listing criterion; `swap` does not check it.
    /// @param token Pool token sold.
    /// @param debtAsset Debt asset bought.
    /// @param kind 0 primary, 1 backup.
    /// @param depthThreshold New threshold, base units of `debtAsset`.
    function tightenRouteDepthThreshold(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind,
        uint256 depthThreshold
    ) external;

    /// @notice Lowers a market's `marketUsdCap`; existing records are unaffected.
    /// @dev 0 is allowed; exits, repay, liquidation and rescue top-ups stay open.
    /// @param value New cap, 8-decimal USD.
    function tightenMarketUsdCap(
        uint256 marketId,
        uint256 value
    ) external;

    /// @notice Lowers a market's `topUpSliceUsd`.
    /// @param value New slice budget, 8-decimal USD.
    function tightenTopUpSliceUsd(
        uint256 marketId,
        uint256 value
    ) external;

    /// @notice Lowers a token's `tokenUsdCap(hub, token)`.
    /// @dev 0 is allowed.
    /// @param value New cap, 8-decimal USD.
    function tightenTokenUsdCap(
        address hub,
        address token,
        uint256 value
    ) external;

    /// @notice Raises a market's `minPledgeUsd`.
    /// @param value New minimum, 8-decimal USD.
    function tightenMinPledgeUsd(
        uint256 marketId,
        uint256 value
    ) external;
}
