// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IParameterStoreLoosen
/// @notice Loosen setters of the ParameterStore: each moves one risk parameter in its riskier direction.
/// @dev Timelock only, at the normal delay. Step-limited parameters move one step at most once per `normalDelay`.
interface IParameterStoreLoosen {
    /// @notice Raises a market's `slippageAllowanceBps`.
    /// @dev At most `LOOSEN_SLIPPAGE_STEP_BPS` above the current value.
    function loosenSlippageAllowanceBps(
        uint256 marketId,
        uint16 value
    ) external;

    /// @notice Raises a debt asset's `floorRoundingAllowance`.
    /// @param value New allowance, base units of `asset`.
    function loosenFloorRoundingAllowance(
        address asset,
        uint256 value
    ) external;

    /// @notice Lowers a swap-route slot's depth threshold.
    /// @param token Pool token sold.
    /// @param debtAsset Debt asset bought.
    /// @param kind 0 primary, 1 backup.
    /// @param depthThreshold New threshold, base units of `debtAsset`.
    function loosenRouteDepthThreshold(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind,
        uint256 depthThreshold
    ) external;

    /// @notice Raises a market's `marketUsdCap`, by at most one step; `USD_CAP_REOPEN_BASE` lets a zero cap reopen.
    /// @dev Reverts `AddCapTooSmall` when the Hub `addCap` is too small for the new value.
    /// @param value New cap, 8-decimal USD.
    function loosenMarketUsdCap(
        uint256 marketId,
        uint256 value
    ) external;

    /// @notice Raises a market's `topUpSliceUsd`.
    /// @dev Reverts `AddCapTooSmall` when the Hub `addCap` is too small for the new value.
    /// @param value New slice budget, 8-decimal USD.
    function loosenTopUpSliceUsd(
        uint256 marketId,
        uint256 value
    ) external;

    /// @notice Raises a token's `tokenUsdCap(hub, token)`, by at most one step.
    /// @dev Reverts `LoosenStepTooLarge` for a pair whose cap `setInitialTokenCap` never wrote.
    /// @param value New cap, 8-decimal USD.
    function loosenTokenUsdCap(
        address hub,
        address token,
        uint256 value
    ) external;

    /// @notice Lowers a market's `minPledgeUsd`.
    /// @param value New minimum, 8-decimal USD.
    function loosenMinPledgeUsd(
        uint256 marketId,
        uint256 value
    ) external;
}
