// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IMarketRegistryRoutes
/// @notice Governance of swap routes (a pool token to a debt asset, used by settlement). There is no
/// in-kind settlement (Q-401).
/// @dev Every function requires `APPLICATION_ADMIN` (the chain's timelock). `kind` is the slot: 0 primary, 1 backup.
/// Swap routes are keyed by `(marketId, token, debtAsset)`: a liquidation flash-borrows the debt asset, unwinds the
/// seized units into the market's n pool tokens and swaps each token other than the debt asset straight into the debt
/// asset, so no intermediate asset sits between a pool token and the debt being repaid. A pool token
/// equal to the debt asset needs no route. Setting a route marks it previously approved for its slot; a restore can
/// only bring back such a route.
interface IMarketRegistryRoutes {
    /// @notice Adds or changes the primary or backup swap route of a market's pool token into a debt asset.
    /// @dev Normal delay. Reverts `UnknownMarket` for an unknown market, `TokenNotListed` unless `token` is one of the
    /// market's pool tokens and `debtAsset` is the asset of an enabled debt reserve of the market's CDP Spoke, and
    /// `InvalidRoute` unless `route.tokenIn() == token`, `route.tokenOut() == debtAsset`, `route.LP_VAULT_SWAP() ==
    /// LP_VAULT_SWAP`, no entry of `route.dependencies()` is the market's own pool (selling into the pool being
    /// unwound would move the price the liquidation is valued at), the two slots are distinct and share no
    /// dependency, a backup avoids every peg module (GSM or PSM) of the pair, `route.supportsTokenClass(token)`
    /// covers the token's class (stable, correlated or volatile, AMMN-FLOW-14), and no token of
    /// `route.exactAmountInputs()` is a listed token with the `UsdtFeeRate` issuer probe (REQ-ROUTE-008). Emits
    /// `RouteSet`.
    /// @param marketId Market identifier.
    /// @param token Pool token sold.
    /// @param debtAsset Debt asset bought.
    /// @param kind 0 primary, 1 backup.
    /// @param route Swap route contract (`ISettlementRoute`).
    /// @custom:spec REQ-CONFIG-039, REQ-CONFIG-040, REQ-CONFIG-059, REQ-CONFIG-060, Q-379
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
    /// @dev Short delay. Reverts `NotPreviouslyApproved` unless the address was set for the slot by `setRoute`, and
    /// `InvalidRoute` when the route checks fail. Emits `RouteRestored`.
    /// @param marketId Market identifier.
    /// @param token Pool token.
    /// @param debtAsset Debt asset.
    /// @param kind 0 primary, 1 backup.
    /// @param route Previously approved route contract.
    /// @custom:spec REQ-CONFIG-062
    function restoreRoute(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind,
        address route
    ) external;
}
