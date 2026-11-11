// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DexPathRoute} from "../../../src/liquidation/settlement-routes/DexPathRoute.sol";
import {ISettlementRoute} from "../../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {DexHop, HopKind} from "../../../src/liquidation/settlement-routes/types/DexHop.sol";
import {RouteConfig} from "../../../src/liquidation/settlement-routes/types/RouteConfig.sol";
import {Lock} from "../../../src/lock/lock/Lock.sol";
import {LockMember} from "../../utils/mocks/LockMember.sol";
import {PayoutToken} from "../../utils/mocks/PayoutToken.sol";
import {MockCLPool, MockCurvePool, MockPoolFactory, MockRouteCaller} from "../../utils/mocks/SwapRouteMocks.sol";

/// @title DexPathRouteProperties
/// @notice Echidna and Medusa properties of the `DexPath` swap route (2.12): a two-hop cbETH → WETH → USDC route over a
/// concentrated-liquidity pool and a Curve pool. Between transactions: the route holds exactly the tokens donated to it,
/// grants no allowance, keeps its immutables, and the Lock is free. Inside one transaction: LPVaultSwap's swap under the
/// Lock delivers at least `minOut` and returns LPVaultSwap's delta, or reverts `MinOutNotMet`; residues come back to
/// LPVaultSwap; any other caller and any callback outside a hop are refused.
/// @dev `property_` functions run in property mode; `swap`, `outsiderSwap`, `callbackOutsideHop` and `donate` run in
/// assertion mode, each selecting among concrete pool states with `if` branches.
contract DexPathRouteProperties {
    Lock internal immutable LOCK;
    MockRouteCaller internal immutable SWAP;
    LockMember internal immutable ADAPTER;
    PayoutToken internal immutable CBETH;
    PayoutToken internal immutable WETH;
    PayoutToken internal immutable USDC;
    MockCLPool internal immutable POOL1;
    MockCurvePool internal immutable POOL2;
    DexPathRoute internal immutable ROUTE;

    uint256[3] internal donated;

    /// @notice Number of assertion sequences run; written so each call is a transaction.
    uint256 public sequences;

    constructor() {
        SWAP = new MockRouteCaller();
        ADAPTER = new LockMember();
        LOCK = new Lock(address(ADAPTER), address(SWAP));
        SWAP.setLock(LOCK);
        ADAPTER.setLock(LOCK);
        CBETH = new PayoutToken("cbETH", 18);
        WETH = new PayoutToken("WETH", 18);
        USDC = new PayoutToken("USDC", 6);
        POOL1 = new MockCLPool(address(CBETH), address(WETH));
        address[] memory coins = new address[](2);
        coins[0] = address(WETH);
        coins[1] = address(USDC);
        POOL2 = new MockCurvePool(coins);
        POOL2.setRate(3000e6, 1e18);
        WETH.mint(address(POOL1), 1e40);
        USDC.mint(address(POOL2), 1e40);
        MockPoolFactory v3Factory = new MockPoolFactory();
        MockPoolFactory curveFactory = new MockPoolFactory();
        v3Factory.register(address(POOL1));
        curveFactory.registerCurve(address(POOL2), coins);
        DexHop[] memory hops = new DexHop[](2);
        hops[0] =
            DexHop({kind: HopKind.ConcentratedLiquidity, pool: address(POOL1), tokenOut: address(WETH), i: 0, j: 0});
        hops[1] = DexHop({kind: HopKind.CurveStableSwap, pool: address(POOL2), tokenOut: address(USDC), i: 0, j: 1});
        ROUTE = new DexPathRoute(
            RouteConfig({
                lpVaultSwap: address(SWAP),
                lock: address(LOCK),
                aaveAdapter: address(ADAPTER),
                tokenIn: address(CBETH),
                tokenOut: address(USDC),
                tokenClassMask: 1 << 2,
                uniswapV3Factory: address(v3Factory),
                slipstreamFactory: address(0),
                curveFactory: address(curveFactory)
            }),
            hops
        );
    }

    // ─── Properties (between transactions) ───

    function property_routeHoldsOnlyDonations() external view returns (bool) {
        return CBETH.balanceOf(address(ROUTE)) == donated[0] && WETH.balanceOf(address(ROUTE)) == donated[1]
            && USDC.balanceOf(address(ROUTE)) == donated[2];
    }

    function property_noAllowanceOutstanding() external view returns (bool) {
        return WETH.allowance(address(ROUTE), address(POOL2)) == 0
            && CBETH.allowance(address(ROUTE), address(POOL1)) == 0
            && CBETH.allowance(address(SWAP), address(ROUTE)) == 0;
    }

    function property_immutablesFixedAndLockFree() external view returns (bool) {
        return ROUTE.LP_VAULT_SWAP() == address(SWAP) && ROUTE.AAVE_ADAPTER() == address(ADAPTER)
            && ROUTE.tokenIn() == address(CBETH) && ROUTE.tokenOut() == address(USDC) && ROUTE.routeType() == 1
            && !LOCK.isLocked();
    }

    // ─── Assertion entry points (inside one transaction) ───

    /// @notice LPVaultSwap swaps under the Lock against one of four pool states (rate, depth).
    function swap(
        uint64 amountIn,
        uint64 minOut,
        uint8 poolCase
    ) external {
        if (poolCase % 4 == 0) {
            POOL1.setRate(1, 1);
            POOL1.setMaxIn(type(uint256).max);
        } else if (poolCase % 4 == 1) {
            POOL1.setRate(99, 100); // a sandwiched first hop
            POOL1.setMaxIn(type(uint256).max);
        } else if (poolCase % 4 == 2) {
            POOL1.setRate(1, 1);
            POOL1.setMaxIn(1e9); // a thin pool: the rest of the input comes back
        } else {
            POOL1.setRate(0, 1); // a pool returning nothing
            POOL1.setMaxIn(type(uint256).max);
        }
        CBETH.mint(address(SWAP), amountIn);
        uint256 inBefore = CBETH.balanceOf(address(SWAP));
        uint256 outBefore = USDC.balanceOf(address(SWAP));
        try SWAP.swapUnderLock(ROUTE, amountIn, minOut) returns (uint256 out) {
            assert(out >= minOut && USDC.balanceOf(address(SWAP)) - outBefore == out);
            assert(inBefore - CBETH.balanceOf(address(SWAP)) <= amountIn);
            assert(WETH.balanceOf(address(ROUTE)) == donated[1]);
        } catch (bytes memory reason) {
            bytes4 sel = bytes4(reason);
            assert(
                sel == ISettlementRoute.MinOutNotMet.selector || sel == ISettlementRoute.TransferMismatch.selector
                    || (sel == ISettlementRoute.ZeroMinOut.selector && minOut == 0)
            );
            assert(sel != ISettlementRoute.TransferMismatch.selector || amountIn == 0);
        }
        ++sequences;
    }

    /// @notice Anyone but LPVaultSwap is refused, with the Lock free or held by the AaveAdapter.
    function outsiderSwap(
        uint64 amountIn,
        bool adapterHolds
    ) external {
        bytes memory call = abi.encodeCall(ISettlementRoute.swap, (amountIn, 1));
        if (adapterHolds) {
            (bool ok, bytes memory reason) = ADAPTER.acquireCallRelease(address(ROUTE), call);
            assert(!ok && bytes4(reason) == ISettlementRoute.NotLPVaultSwap.selector);
        } else {
            try ROUTE.swap(amountIn, 1) {
                assert(false);
            } catch (bytes memory reason) {
                assert(bytes4(reason) == ISettlementRoute.NotLPVaultSwap.selector);
            }
        }
        ++sequences;
    }

    /// @notice A callback outside a hop is refused, from the route's own pool or anyone else.
    function callbackOutsideHop(
        int128 amount0,
        int128 amount1,
        bool fromPool
    ) external {
        if (fromPool) {
            try POOL1.poke(address(ROUTE), amount0, amount1) {
                assert(false);
            } catch (bytes memory reason) {
                assert(bytes4(reason) == ISettlementRoute.InvalidCallback.selector);
            }
        } else {
            try ROUTE.uniswapV3SwapCallback(amount0, amount1, "") {
                assert(false);
            } catch (bytes memory reason) {
                assert(bytes4(reason) == ISettlementRoute.InvalidCallback.selector);
            }
        }
        ++sequences;
    }

    /// @notice A plain transfer to the route stays there and counts toward nothing.
    function donate(
        uint32 dust,
        uint8 which
    ) external {
        if (which % 3 == 0) CBETH.mint(address(ROUTE), dust);
        else if (which % 3 == 1) WETH.mint(address(ROUTE), dust);
        else USDC.mint(address(ROUTE), dust);
        donated[which % 3] += dust;
        ++sequences;
    }
}
