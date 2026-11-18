// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ISettlementRoute
/// @notice Common surface of every swap route: an immutable contract swapping one pool token into one debt asset.
/// @dev Each call ends with no token balance change in the route and no allowance outstanding.
interface ISettlementRoute {
    error NotLPVaultSwap();

    /// @notice The lock contract reports the lock held by neither LPVaultSwap nor the AaveAdapter.
    error NotLocked();

    /// @notice The route received no input, or more than `amountIn`, measured as its input-token balance delta.
    error TransferMismatch();

    /// @notice The debt asset delivered to LPVaultSwap is below the oracle-derived minimum LPVaultSwap passed.
    error MinOutNotMet(uint256 out, uint256 minOut);

    /// @notice A concentrated-liquidity swap callback came from an unexpected address or outside a hop.
    error InvalidCallback();

    /// @notice LPVaultSwap passed `minOut = 0`; every route call carries an oracle-derived minimum of at least 1.
    error ZeroMinOut();

    error InvalidRouteConfig();

    /// @notice Swaps `amountIn` of the input token into at least `minOut` of the debt asset for LPVaultSwap.
    /// @dev Only LPVaultSwap, while the lock is held by LPVaultSwap or the AaveAdapter.
    /// @return amountOut Debt asset sent to LPVaultSwap, measured as its balance delta.
    function swap(
        uint256 amountIn,
        uint256 minOut
    ) external returns (uint256 amountOut);

    /// @notice Pays the pool during a hop on a Uniswap v3 or Aerodrome Slipstream pool.
    /// @dev Reverts `InvalidCallback` unless `msg.sender` is the pool of the hop in progress.
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external;

    /// @notice Input token of the route (a pool token).
    function tokenIn() external view returns (address token);

    /// @notice Output token of the route: the debt asset.
    function tokenOut() external view returns (address token);

    /// @notice Route type (`ROUTE_TYPE`), fixed at deployment.
    /// @return typeId 0 PegModule, 1 DexPath, 2 WrapperThenDex.
    function routeType() external view returns (uint8 typeId);

    /// @notice Every external contract the route calls beyond ERC-20 transfers, approvals and balance reads.
    function dependencies() external view returns (address[] memory contracts);

    /// @notice Returns every token the route holds between legs, in leg order; empty for a route of one leg.
    function intermediates() external view returns (address[] memory tokens);

    /// @notice Returns every token the route pays into a contract that requires the exact amount it was sent.
    /// @dev Such a token must have no transfer-fee switch.
    function exactAmountInputs() external view returns (address[] memory tokens);

    /// @notice Returns the pinned pool factories the constructor checked every hop pool against; 0 when none.
    function poolFactories() external view returns (address uniswapV3, address slipstream, address curve);

    /// @notice The only allowed caller of `swap`.
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice AaveAdapter fixed proxy address, the second lock holder the route accepts.
    function AAVE_ADAPTER() external view returns (address adapter);

    /// @notice Whether the route is approved for a token class.
    /// @param tokenClass 1 stable, 2 correlated, 3 volatile (the `RiskTier` ordinals).
    function supportsTokenClass(
        uint8 tokenClass
    ) external view returns (bool supported);
}
