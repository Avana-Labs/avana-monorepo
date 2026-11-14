// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IMarketRegistryRoutes
/// @notice Governance of swap routes (a pool token to a debt asset, used by settlement). There is no
/// in-kind settlement (Q-401).
/// @dev Every function requires `APPLICATION_ADMIN` (the chain's timelock). `kind` is the slot: 0 primary, 1 backup.
/// Swap routes are keyed by `(marketId, token, debtAsset)`: a liquidation, through LPVaultSwap's one entry point
/// `liquidate`, is funded by its caller in the debt asset (from its own balance or through a flash liquidation
/// helper), and `deleverage` flash-borrows the debt asset through the chain's IFlashSource; either way the seized units
/// are unwound into the market's n pool tokens and each token other than the debt asset is swapped straight into the
/// debt asset, so no intermediate asset sits between a pool token and the debt being repaid. A pool token
/// equal to the debt asset needs no route. Setting a route marks it previously approved for its slot; a restore can
/// only bring back such a route.
interface IMarketRegistryRoutes {
    /// @notice Adds or changes the primary or backup swap route of a market's pool token into a debt asset.
    /// @dev Normal delay. Reverts `UnknownMarket` for an unknown, Cancelled or Closed market, `TokenNotListed` unless
    /// `token` is one of the market's pool tokens and `debtAsset` is the asset of an enabled debt reserve of the
    /// market's CDP Spoke, a listed token, or an asset with a First-Loss Reserve on the Spoke's home Hub (so the routes of a
    /// debt reserve can be set in the batch that enables it), and `InvalidRoute` unless the market's integration has a
    /// finalized record of AMM protocol contracts whose key still matches it (REQ-MREG-035), `route.tokenIn() ==
    /// token`, `route.tokenOut() == debtAsset`, `route.LP_VAULT_SWAP() == LP_VAULT_SWAP`, no entry of
    /// `route.dependencies()` is the market's own pool (selling into the pool being unwound would move the price the
    /// liquidation is valued at), its integration's LPVault or an AMM contract recorded for its integration, the two
    /// slots are distinct and share no
    /// dependency, a backup avoids every peg module (GSM or PSM) of the pair, `route.supportsTokenClass(token)`
    /// covers the token's class (stable, correlated or volatile, AMMN-FLOW-14), and no token of
    /// `route.exactAmountInputs()` is a listed token whose issuer probe reads `basisPointsRate()` (`UsdtFeeRate` or
    /// `UsdtFeeRateAndPaused`, REQ-ROUTE-008). Also `InvalidRoute` unless `route.routeType()` is 0, 1 or 2 and, for a
    /// `PegModule` route (0), `pegModule()` names a module listed in `dependencies()` that is a LitePSM, or a GSM in the
    /// backup slot that answers `getIsSeized() == false`, `getIsFrozen() == false` and `getExposureCap() > 0`
    /// (REQ-ROUTE-002, Q-341), and unless no token among `token`, `debtAsset` and `route.intermediates()` has an
    /// ERC-1820 `ERC777Token` implementer (Q-342). Each of these reads must return exactly the expected length; a
    /// revert or a shorter or longer answer refuses the route. A different route the slot held before leaves the
    /// slot's previously approved set (REQ-ROUTE-017), so only the slot's current route can be restored. Emits
    /// `RouteSet`.
    /// @param marketId Market identifier.
    /// @param token Pool token sold.
    /// @param debtAsset Debt asset bought.
    /// @param kind 0 primary, 1 backup.
    /// @param route Swap route contract (`ISettlementRoute`).
    /// @custom:spec REQ-CONFIG-039, REQ-CONFIG-040, REQ-CONFIG-059, REQ-CONFIG-060, REQ-MREG-035, REQ-ROUTE-002, REQ-ROUTE-005, REQ-ROUTE-017, Q-341, Q-342, Q-379
    function setRoute(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind,
        address route
    ) external;

    /// @notice Disables a swap route until it is restored or replaced.
    /// @dev Short delay. No expiry. Emits `RouteDisabled`.
    /// @param marketId Market identifier.
    /// @param token Pool token.
    /// @param debtAsset Debt asset.
    /// @param kind 0 primary, 1 backup.
    /// @custom:spec REQ-CONFIG-061
    function disableRoute(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind
    ) external;

    /// @notice Re-enables a previously approved swap route for a slot.
    /// @dev Short delay. Reverts `NotPreviouslyApproved` unless the address was set for the slot by `setRoute` and no
    /// later `setRoute` replaced it, and
    /// `InvalidRoute` when the route checks of `setRoute` fail at the restoring block, the GSM health check and the
    /// ERC-777 check included: a GSM frozen since the route was set keeps it disabled (REQ-ROUTE-019). Emits
    /// `RouteRestored`.
    /// @param marketId Market identifier.
    /// @param token Pool token.
    /// @param debtAsset Debt asset.
    /// @param kind 0 primary, 1 backup.
    /// @param route Previously approved route contract.
    /// @custom:spec REQ-CONFIG-062, REQ-ROUTE-019, Q-341
    function restoreRoute(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind,
        address route
    ) external;
}
