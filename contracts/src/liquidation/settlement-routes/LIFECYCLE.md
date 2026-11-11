# Swap route lifecycle

A swap route is an immutable contract that converts one pool token into one debt asset for LPVaultSwap, delivering at least the oracle-derived minimum LPVaultSwap passes, or reverting so LPVaultSwap can try the backup. Three contracts implement it: [`DexPathRoute`](DexPathRoute.sol) (type 1, one to three Uniswap v3, Slipstream or Curve hops), [`WrapperThenDexRoute`](WrapperThenDexRoute.sol) (type 2, an ERC-4626 redeem or the DAI/USDS converter, then hops) and [`PegModuleRoute`](PegModuleRoute.sol) (type 0, a GSM or the LitePSM). They share [`SwapRouteBase`](SwapRouteBase.sol) (checks, measured pull, residues, minimum) and [`DexHops`](DexHops.sol) (hops and callback).

## Walkthrough

Setup (Ethereum market `m`, Uniswap v3 USDC/USDT, USDC debt, Bob's liquidation of 3.5 `LIQ-069`): the USDT→USDC primary route is a fixed-pool DEX hop; the backup avoids every peg module of the pair.

1. **AvanaTimelock → MarketRegistry [`setRoute`](../../policy/market-registry/IMarketRegistryRoutes.sol#L30)`(m, USDT, USDC, 0, route)`** (normal delay). The registry reads [`tokenIn`](SwapRouteBase.sol#L144) = USDT, [`tokenOut`](SwapRouteBase.sol#L150) = USDC, [`LP_VAULT_SWAP`](SwapRouteBase.sol#L168), [`routeType`](DexPathRoute.sol#L35), [`dependencies`](DexPathRoute.sol#L41) (never market `m`'s own pool; primary and backup share none), [`intermediates`](SwapRouteBase.sol#L156) and [`supportsTokenClass`](SwapRouteBase.sol#L180). Event: MarketRegistry [`RouteSet`](../../policy/market-registry/IMarketRegistryEvents.sol#L121). Error: MarketRegistry `InvalidRoute`.
2. **LPVaultSwap, inside [`liquidate`](../lp-vault-swap/ILPVaultSwapLiquidation.sol#L48), approves the route for exactly the USDT leg (about 1,010 USDT) and calls [`swap`](SwapRouteBase.sol#L85)`(amountIn, minOut)`** with `minOut` the per-leg oracle minimum (USDT leg value less `slippageAllowanceBps` 100). The route pulls the input with `transferFrom`, measures what arrived, runs the hop ([`_runHops`](DexHops.sol#L150)) and sends 1,010.05 USDC to LPVaultSwap; `minOut` is checked on LPVaultSwap's own balance rise. Allowances return to 0. Errors: [`NotLPVaultSwap`](ISettlementRoute.sol#L35), [`NotLocked`](ISettlementRoute.sol#L39), [`TransferMismatch`](ISettlementRoute.sol#L43), [`MinOutNotMet`](ISettlementRoute.sol#L49). The constructor of each route checks its legs against the pools, wrapper and peg module and reverts [`InvalidRouteConfig`](ISettlementRoute.sol#L66) on a mis-wired leg.
3. **Pool → [`uniswapV3SwapCallback`](DexHops.sol#L128)** during a Uniswap v3 or Slipstream hop: the route pays the pool only when `msg.sender` is the hop's fixed pool stored in transient storage, only on the hop's input side, at most the hop's amount, and once. Error: [`InvalidCallback`](ISettlementRoute.sol#L53).
4. **Residue.** Any unconsumed input or intermediate token (input a thin pool did not take, WETH between two hops, a GSM's unsold shares, DAI below one USDC unit at the LitePSM) goes back to LPVaultSwap in the same call, which sends it to the caller or escrows it in the PayoutEscrow ([`ResidueReturned`](../lp-vault-swap/ILPVaultSwapEvents.sol#L65)).
5. **Failure and fallback.** A sandwich pushing the hop below `minOut` (for example 6,100e6 against a minimum of about 6,148.69e6 on a 6,211.3 USDC leg) reverts `MinOutNotMet` with no state change; LPVaultSwap emits [`RouteFailed`](../lp-vault-swap/ILPVaultSwapEvents.sol#L56) and calls the backup. With no usable route, LPVaultSwap reverts `NoRouteAvailable`.
6. **Other callers.** The same `swap` runs inside LPVaultSwap [`settlePending`](../lp-vault-swap/ILPVaultSwapLiquidation.sol#L76) and [`deleverage`](../lp-vault-swap/ILPVaultSwapDeleverage.sol#L32) (V's 1,500 USDT convert to 1,499.40 USDC, above the minimum of 1,485); during a repay with collateral the Lock holder is the AaveAdapter, which the route accepts.
7. **AvanaTimelock → MarketRegistry [`disableRoute`](../../policy/market-registry/IMarketRegistryRoutes.sol#L45)** (short delay) on a route that keeps failing; [`restoreRoute`](../../policy/market-registry/IMarketRegistryRoutes.sol#L61) brings back only a previously approved route. Three route failures in an hour raise a monitoring alert; a guardian freezes new borrowing on the market only once the approved routes are confirmed unable to settle at size.

## What the UI reads and calls

- Lens: [`previewLiquidation`](../../lens/lens/ILensLiquidation.sol#L84) (`routeMode` is `BackupOnly` when a primary route is unusable); MarketRegistry [`getRoute`](../../policy/market-registry/IMarketRegistryRouteViews.sol#L51).
- Events to index: LPVaultSwap `RouteFailed`, `ResidueReturned`; MarketRegistry `RouteSet`, `RouteDisabled`, `RouteRestored`.
- User calls: none; only LPVaultSwap calls `swap`.

## Spec

- [2.12 Settlement Routes](../../../../spec/02-contracts/12-settlement-routes.md): `REQ-ROUTE-002`–`REQ-ROUTE-016`, `REQ-ROUTE-023`–`REQ-ROUTE-029`, `REQ-ROUTE-036`, `REQ-ROUTE-037`, `REQ-ROUTE-042`–`REQ-ROUTE-044`.
- [2.11 LPVaultSwap](../../../../spec/02-contracts/11-lpvaultswap.md) `SPEC-LIQ-018` (per-leg minimum); [3.5](../../../../spec/03-operations/05-liquidation.md) `LIQ-075`.
