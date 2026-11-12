// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ISettlementRoute
/// @notice Common surface of every swap route: an immutable contract that swaps one pool token into one debt asset
/// inside an LPVaultSwap call, along a path fixed at deployment. Each market's pool token other than the debt asset has
/// a primary and an independent backup swap route per enabled debt asset, selected through the MarketRegistry records
/// `getRoute(marketId, token, debtAsset, kind)` (kind 0 primary, 1 backup). A slot is usable when its record is Active;
/// no guardian suspension or quarantine exists.
/// @dev Route types (`routeType()`): 0 `PegModule` (a peg module of the pair, such as a GSM or PSM, where its live
/// capacity covers the leg; never the only route of a token, because a GSM's capacity can fall to near 0), 1 `DexPath`
/// (fixed hops over Uniswap v3, Aerodrome Slipstream, Curve StableSwap-NG or pinned legacy Curve pools ending in the
/// debt asset), 2 `WrapperThenDex` (an unwrap or redeem step such as a static aToken or a rate token, then `DexPath` hops). Each route
/// declares the token classes it covers (`supportsTokenClass`: stable, correlated or volatile), and the route test
/// stresses a fully one-sided unwind of a concentrated range (AMMN-FLOW-14, AMMN-RT-09). Constructor arguments, all
/// immutable: `LP_VAULT_SWAP` (the only allowed caller), `LOCK`, `AAVE_ADAPTER` (the second accepted lock holder),
/// `TOKEN_IN`, `TOKEN_OUT` (the debt asset), `ROUTE_TYPE`, and the type's legs (pool addresses or identifiers, Curve
/// indices, swap directions, wrapper and peg-module addresses). A route has no owner, setter, rescue, sweep or
/// arbitrary-call function, writes no storage outside transient storage, ends every call with no change in any of its
/// token balances and no allowance outstanding (a token sent to it outside a call stays there unused), never
/// calls the market's own pool (every hop's pool is listed in `dependencies()`), and emits no events (LPVaultSwap
/// emits `RouteFailed`). Each call carries an oracle-derived `minOut` from LPVaultSwap (SPEC-LIQ-018), checked
/// against LPVaultSwap's balance delta of the debt asset after the last leg; every hop runs with a zero minimum and the
/// extreme price limit. LPVaultSwap's aggregate floors still apply over the whole call. Every
/// leg completes inside the LPVaultSwap call; no off-chain or batch-settled step is used. Every route is in the
/// address-freeze protected set and reads no pause, breaker or freeze. Route records change only through the chain's
/// AvanaTimelock: `setRoute` at the normal delay, `disableRoute` and `restoreRoute` at the short delay (an operation
/// of restores only is cancellable only by `DAO_CANCELLER_ROLE`).
/// @custom:spec REQ-ROUTE-002, REQ-ROUTE-004, REQ-ROUTE-009, REQ-ROUTE-016, REQ-ROUTE-023, REQ-ROUTE-024, REQ-ROUTE-037, REQ-ROUTE-042, REQ-ROUTE-043, Q-062, Q-085, Q-124, Q-235, Q-242, Q-250, Q-263, Q-273, Q-379
interface ISettlementRoute {
    /// @notice The caller is not LPVaultSwap.
    /// @custom:spec REQ-ROUTE-007, REQ-ROUTE-025
    error NotLPVaultSwap();

    /// @notice The lock contract reports the lock held by neither LPVaultSwap nor the AaveAdapter.
    /// @custom:spec REQ-ROUTE-007, REQ-ROUTE-025
    error NotLocked();

    /// @notice The route received no input, or more than `amountIn`, measured as its input-token balance delta.
    /// @custom:spec REQ-ROUTE-008
    error TransferMismatch();

    /// @notice The debt asset delivered to LPVaultSwap is below the oracle-derived minimum LPVaultSwap passed.
    /// @param out Debt asset delivered, measured as LPVaultSwap's balance delta, base units.
    /// @param minOut The minimum LPVaultSwap passed, base units.
    /// @custom:spec REQ-ROUTE-009, REQ-ROUTE-042, REQ-ROUTE-044
    error MinOutNotMet(uint256 out, uint256 minOut);

    /// @notice A concentrated-liquidity swap callback came from an unexpected address or outside a hop.
    /// @custom:spec REQ-ROUTE-013, REQ-ROUTE-029
    error InvalidCallback();

    /// @notice LPVaultSwap passed `minOut = 0`; every route call carries an oracle-derived minimum of at least 1.
    /// @custom:spec REQ-ROUTE-042
    error ZeroMinOut();

    /// @notice A constructor argument fails the route's deployment checks (a zero address, a Lock whose members are not
    /// LPVaultSwap and the AaveAdapter, equal input and output tokens, a token-class mask outside bits 1 to 3, legs
    /// that do not connect the input token to the output token through the named pools, wrapper or peg module, a pool
    /// that is not the pinned factory's pool for its tokens, a token with a transfer-fee switch paid into a
    /// concentrated-liquidity pool or a GSM's static aToken, or a named contract that does not answer a read the check
    /// makes). Every failed deployment check reverts with this error.
    /// @custom:spec REQ-ROUTE-008, REQ-ROUTE-045
    error InvalidRouteConfig();

    /// @notice Swaps `amountIn` of the input token into at least `minOut` of the debt asset and sends it and any residue
    /// to LPVaultSwap.
    /// @dev Called by LPVaultSwap inside `liquidate`, `settlePending` or `deleverage`, and
    /// completes inside that call. The call
    /// reverts with `NotLPVaultSwap` unless `msg.sender == LP_VAULT_SWAP` and `NotLocked` unless the lock is held by
    /// LPVaultSwap or the AaveAdapter. Requests `amountIn` with `transferFrom(LP_VAULT_SWAP, route, amountIn)`, measures the amount received
    /// as a balance delta, reverts `TransferMismatch` if it is 0 or above `amountIn`, and runs every leg on the amount
    /// received; `minOut` is not reduced for a transfer fee. A token whose issuer can switch on a transfer fee (USDT)
    /// is never paid into a leg that requires the exact amount it was sent (a concentrated-liquidity pool, a GSM's
    /// static aToken): the constructor and the listing refuse such a route, so with the fee on such a token reaches a
    /// pool only through a Curve hop (StableSwap-NG or a pinned legacy pool), whose output the route measures. Checks
    /// `minOut` against LPVaultSwap's balance delta of the debt asset after the last leg and
    /// reverts `MinOutNotMet(out, minOut)` below it. Example: a 6,211.3 USDC leg into USDT with `minOut` ≈ 6,148.69e6 passes on a pool returning
    /// 6,209.8e6 and reverts on a sandwiched pool returning 6,100e6. Approves each step for exactly the leg input and
    /// resets the allowance to 0 after the leg. Transfers every non-zero unconsumed input or intermediate token to
    /// LPVaultSwap; a zero leftover is skipped.
    /// A step failure (peg module frozen or at its cap, wrapper paused, pool or Curve call failing, a token paused or
    /// blocklisting LPVaultSwap) makes the whole call revert with no state change, and LPVaultSwap falls back to the backup.
    /// @param amountIn Input-token amount LPVaultSwap sends, base units of `tokenIn()`.
    /// @param minOut Oracle-derived minimum debt-asset output, base units; LPVaultSwap always passes at least 1.
    /// @return amountOut Debt asset sent to LPVaultSwap, measured as a balance delta (LPVaultSwap measures its own
    /// delta).
    /// @custom:spec REQ-ROUTE-007, REQ-ROUTE-008, REQ-ROUTE-009, REQ-ROUTE-010, REQ-ROUTE-011, REQ-ROUTE-012, REQ-ROUTE-014, REQ-ROUTE-015, REQ-ROUTE-016, REQ-ROUTE-024, REQ-ROUTE-026, REQ-ROUTE-037, REQ-ROUTE-042, REQ-ROUTE-044, Q-213, Q-217, Q-235, Q-250, Q-271
    function swap(
        uint256 amountIn,
        uint256 minOut
    ) external returns (uint256 amountOut);

    /// @notice Pays the pool during a hop on a Uniswap v3 or Aerodrome Slipstream pool (both call
    /// `uniswapV3SwapCallback`); swap-route plumbing for `DexPath` hops on those pools.
    /// @dev The call reverts with `InvalidCallback` unless `msg.sender` is the hop's fixed pool stored in transient storage and a hop
    /// is in progress; pays exactly the positive amount owed in the hop's input token and nothing else. Routes without such
    /// a hop never have a hop in progress, so the call always reverts there.
    /// @param amount0Delta Pool token0 delta (positive = owed to the pool).
    /// @param amount1Delta Pool token1 delta (positive = owed to the pool).
    /// @param data Hop data passed to `pool.swap`.
    /// @custom:spec REQ-ROUTE-013, REQ-ROUTE-029
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external;

    /// @notice Input token of the route (a pool token).
    /// @return token `TOKEN_IN`.
    /// @custom:spec REQ-ROUTE-005, REQ-ROUTE-036
    function tokenIn() external view returns (address token);

    /// @notice Output token of the route.
    /// @return token The debt asset.
    /// @custom:spec REQ-ROUTE-005, REQ-ROUTE-036
    function tokenOut() external view returns (address token);

    /// @notice Route type (`ROUTE_TYPE`), fixed at deployment.
    /// @return typeId 0 PegModule, 1 DexPath, 2 WrapperThenDex.
    /// @custom:spec REQ-ROUTE-002, REQ-ROUTE-005
    function routeType() external view returns (uint8 typeId);

    /// @notice Every external contract the route calls for anything other than an ERC-20 `transfer`, `transferFrom`,
    /// `approve` or `balanceOf`: pools, wrappers and peg modules, including a wrapper that is also the input or an
    /// intermediate token (an ERC-4626 vault redeemed, a static aToken deposited into).
    /// @dev Used by the MarketRegistry (2.8 `REQ-CONFIG-040`) to check that a route never calls the market's own pool
    /// or its integration's LPVault (and, for a market keyed by pool identifier, no AMM contract recorded for its
    /// integration, the singleton among them), that the primary and backup of one slot share no dependency, and that a
    /// backup avoids the peg module (`TokenDef.pegModule`) of every pool token of the market; a debt asset's own peg
    /// module, such as the GHO GSM, may serve the backup. It lists every pool the route trades through, on every hop.
    /// @return contracts Pool, wrapper and peg-module addresses.
    /// @custom:spec REQ-ROUTE-003, REQ-ROUTE-004, REQ-ROUTE-005, REQ-ROUTE-036, REQ-ROUTE-043
    function dependencies() external view returns (address[] memory contracts);

    /// @notice Returns every token the route holds between legs, in leg order: a `WrapperThenDex` step's output (unless
    /// it is the debt asset), a GSM route's static aToken, a USDS route's DAI and the output of every DEX hop but the
    /// last; empty for a route of one leg.
    /// @dev The MarketRegistry checks each intermediate token against the route checks of the pool token and the debt
    /// asset, so a multi-leg route cannot pass value through an unchecked token.
    /// @return tokens Intermediate tokens.
    /// @custom:spec REQ-ROUTE-003, REQ-ROUTE-036
    function intermediates() external view returns (address[] memory tokens);

    /// @notice Returns every token the route pays into a contract that requires the exact amount it was sent: the input
    /// of each concentrated-liquidity hop (Uniswap v3 and Slipstream check their balance after the callback) and the
    /// input of a GSM route (the static aToken supplies the amount it pulled to the Aave Pool).
    /// @dev The constructor refuses a route that would pay such a contract a token answering the USDT fee-switch probe
    /// `basisPointsRate()`, and the MarketRegistry refuses one whose listed token has an issuer probe reading it
    /// (`UsdtFeeRate` or `UsdtFeeRateAndPaused`), so a transfer fee switched on can stop neither route of a slot
    /// (REQ-ROUTE-003, REQ-ROUTE-008).
    /// @return tokens The tokens, in leg order.
    /// @custom:spec REQ-ROUTE-003, REQ-ROUTE-005, REQ-ROUTE-008
    function exactAmountInputs() external view returns (address[] memory tokens);

    /// @notice Returns the pinned pool factories the constructor checked every hop pool against.
    /// @dev The deployment verification compares them with the chain's address book.
    /// @return uniswapV3 The Uniswap v3 factory (0 when the chain has none).
    /// @return slipstream The Aerodrome Slipstream factory (0 when the chain has none).
    /// @return curve The Curve StableSwap-NG factory (0 when the chain has none).
    /// @custom:spec REQ-ROUTE-045
    function poolFactories() external view returns (address uniswapV3, address slipstream, address curve);

    /// @notice The only allowed caller of `swap`.
    /// @return lpVaultSwap LPVaultSwap's fixed proxy address.
    /// @custom:spec REQ-ROUTE-005, REQ-ROUTE-007
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice AaveAdapter fixed proxy address, the second lock holder the route accepts (a repay with collateral, in
    /// which the AaveAdapter holds the lock and calls LPVaultSwap's `deleverage`).
    /// @return adapter Address.
    /// @custom:spec REQ-ROUTE-007, Q-255
    function AAVE_ADAPTER() external view returns (address adapter);

    /// @notice Whether the route is approved for a token class.
    /// @param tokenClass 1 stable, 2 correlated, 3 volatile (the `RiskTier` ordinals).
    /// @return supported True when the route's depth and path were tested for that class at a fully one-sided unwind.
    /// @custom:spec Q-379
    function supportsTokenClass(
        uint8 tokenClass
    ) external view returns (bool supported);
}
