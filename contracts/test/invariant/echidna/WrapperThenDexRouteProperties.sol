// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ISettlementRoute} from "../../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {WrapperThenDexRoute} from "../../../src/liquidation/settlement-routes/WrapperThenDexRoute.sol";
import {DexHop, HopKind} from "../../../src/liquidation/settlement-routes/types/DexHop.sol";
import {RouteConfig} from "../../../src/liquidation/settlement-routes/types/RouteConfig.sol";
import {WrapperKind, WrapperStep} from "../../../src/liquidation/settlement-routes/types/WrapperStep.sol";
import {Lock} from "../../../src/lock/lock/Lock.sol";
import {LockMember} from "../../utils/mocks/LockMember.sol";
import {PayoutToken} from "../../utils/mocks/PayoutToken.sol";
import {MockCLPool, MockDaiUsds, MockPoolFactory, MockRouteCaller} from "../../utils/mocks/SwapRouteMocks.sol";

/// @title WrapperThenDexRouteProperties
/// @notice Echidna and Medusa properties of the `WrapperThenDex` swap route (2.12): USDS → DAI through the converter,
/// then a DAI/USDC concentrated-liquidity hop. Between transactions: the route holds exactly the tokens donated to it,
/// grants no allowance, keeps its immutables, and the Lock is free. Inside one transaction: LPVaultSwap's swap under the
/// Lock delivers at least `minOut` or reverts `MinOutNotMet`, with residues of DAI back at LPVaultSwap; any other caller
/// and any callback outside a hop are refused.
/// @dev `property_` functions run in property mode; `swap`, `outsiderSwap`, `callbackOutsideHop` and `donate` run in
/// assertion mode with finite branching.
contract WrapperThenDexRouteProperties {
    Lock internal immutable LOCK;
    MockRouteCaller internal immutable SWAP;
    LockMember internal immutable ADAPTER;
    PayoutToken internal immutable USDS;
    PayoutToken internal immutable DAI;
    PayoutToken internal immutable USDC;
    MockDaiUsds internal immutable CONVERTER;
    MockCLPool internal immutable POOL;
    WrapperThenDexRoute internal immutable ROUTE;

    uint256[3] internal donated;

    /// @notice Number of assertion sequences run; written so each call is a transaction.
    uint256 public sequences;

    constructor() {
        SWAP = new MockRouteCaller();
        ADAPTER = new LockMember();
        LOCK = new Lock(address(ADAPTER), address(SWAP));
        SWAP.setLock(LOCK);
        ADAPTER.setLock(LOCK);
        USDS = new PayoutToken("USDS", 18);
        DAI = new PayoutToken("DAI", 18);
        USDC = new PayoutToken("USDC", 6);
        CONVERTER = new MockDaiUsds(address(USDS), address(DAI));
        POOL = new MockCLPool(address(DAI), address(USDC));
        MockPoolFactory v3Factory = new MockPoolFactory();
        v3Factory.register(address(POOL));
        POOL.setRate(1, 1e12);
        USDC.mint(address(POOL), 1e40);
        DexHop[] memory hops = new DexHop[](1);
        hops[0] =
            DexHop({kind: HopKind.ConcentratedLiquidity, pool: address(POOL), tokenOut: address(USDC), i: 0, j: 0});
        ROUTE = new WrapperThenDexRoute(
            RouteConfig({
                lpVaultSwap: address(SWAP),
                lock: address(LOCK),
                aaveAdapter: address(ADAPTER),
                tokenIn: address(USDS),
                tokenOut: address(USDC),
                tokenClassMask: 1 << 1,
                uniswapV3Factory: address(v3Factory),
                slipstreamFactory: address(0),
                curveFactory: address(0)
            }),
            WrapperStep({kind: WrapperKind.UsdsToDai, wrapper: address(CONVERTER), underlying: address(DAI)}),
            hops
        );
    }

    // ─── Properties (between transactions) ───

    function property_routeHoldsOnlyDonations() external view returns (bool) {
        return USDS.balanceOf(address(ROUTE)) == donated[0] && DAI.balanceOf(address(ROUTE)) == donated[1]
            && USDC.balanceOf(address(ROUTE)) == donated[2];
    }

    function property_noAllowanceOutstanding() external view returns (bool) {
        return
            USDS.allowance(address(ROUTE), address(CONVERTER)) == 0
                && USDS.allowance(address(SWAP), address(ROUTE)) == 0;
    }

    function property_immutablesFixedAndLockFree() external view returns (bool) {
        return ROUTE.LP_VAULT_SWAP() == address(SWAP) && ROUTE.tokenIn() == address(USDS)
            && ROUTE.tokenOut() == address(USDC) && ROUTE.routeType() == 2 && !LOCK.isLocked();
    }

    // ─── Assertion entry points (inside one transaction) ───

    /// @notice LPVaultSwap swaps under the Lock against one of three pool states.
    function swap(
        uint64 amountIn,
        uint64 minOut,
        uint8 poolCase
    ) external {
        if (poolCase % 3 == 0) {
            POOL.setRate(1, 1e12);
            POOL.setMaxIn(type(uint256).max);
        } else if (poolCase % 3 == 1) {
            POOL.setRate(98, 100e12); // a sandwiched hop
            POOL.setMaxIn(type(uint256).max);
        } else {
            POOL.setRate(1, 1e12);
            POOL.setMaxIn(1e18); // a thin pool: DAI comes back
        }
        USDS.mint(address(SWAP), amountIn);
        uint256 daiBefore = DAI.balanceOf(address(SWAP));
        uint256 outBefore = USDC.balanceOf(address(SWAP));
        try SWAP.swapUnderLock(ROUTE, amountIn, minOut) returns (uint256 out) {
            assert(out >= minOut && USDC.balanceOf(address(SWAP)) - outBefore == out);
            // Whatever the hop did not take comes back as DAI.
            uint256 taken = poolCase % 3 == 2 && amountIn > 1e18 ? 1e18 : amountIn;
            assert(DAI.balanceOf(address(SWAP)) - daiBefore == amountIn - taken);
        } catch (bytes memory reason) {
            bytes4 sel = bytes4(reason);
            assert(
                sel == ISettlementRoute.MinOutNotMet.selector || sel == ISettlementRoute.TransferMismatch.selector
                    || (sel == ISettlementRoute.ZeroMinOut.selector && minOut == 0)
            );
        }
        ++sequences;
    }

    /// @notice Anyone but LPVaultSwap is refused.
    function outsiderSwap(
        uint64 amountIn
    ) external {
        try ROUTE.swap(amountIn, 1) {
            assert(false);
        } catch (bytes memory reason) {
            assert(bytes4(reason) == ISettlementRoute.NotLPVaultSwap.selector);
        }
        ++sequences;
    }

    /// @notice A callback outside a hop is refused, from the route's pool or anyone else.
    function callbackOutsideHop(
        int128 amount0,
        int128 amount1,
        bool fromPool
    ) external {
        if (fromPool) {
            try POOL.poke(address(ROUTE), amount0, amount1) {
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
        if (which % 3 == 0) USDS.mint(address(ROUTE), dust);
        else if (which % 3 == 1) DAI.mint(address(ROUTE), dust);
        else USDC.mint(address(ROUTE), dust);
        donated[which % 3] += dust;
        ++sequences;
    }
}
