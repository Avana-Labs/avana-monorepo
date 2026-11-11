// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DexPathRoute} from "../../src/liquidation/settlement-routes/DexPathRoute.sol";
import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {DexHop, HopKind} from "../../src/liquidation/settlement-routes/types/DexHop.sol";
import {RouteConfig} from "../../src/liquidation/settlement-routes/types/RouteConfig.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {HalmosRoutePool} from "../utils/mocks/HalmosRoutePool.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {MockPoolFactory} from "../utils/mocks/SwapRouteMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @title DexPathRouteHalmosTest
/// @notice Symbolic checks of the `DexPath` swap route for every caller, Lock state, amount, minimum and pool outcome:
/// `swap` succeeds only for LPVaultSwap while LPVaultSwap or the AaveAdapter holds the Lock; the callback is refused
/// outside a hop; a completed swap delivers at least `minOut` to LPVaultSwap, returns exactly LPVaultSwap's delta, takes
/// at most `amountIn` and leaves the route with no balance; below `minOut` it reverts `MinOutNotMet`.
/// @dev The pool pays a symbolic amount `poolOut` (any outcome, including a sandwich) and takes the whole input.
/// LPVaultSwap and the AaveAdapter are fixed concrete addresses; amounts are bounded to uint128.
contract DexPathRouteHalmosTest is Test {
    address internal constant ADAPTER = address(0xADA9);
    address internal constant SWAP = address(0x5A9);

    Lock internal lock;
    PayoutToken internal usdt;
    PayoutToken internal usdc;
    HalmosRoutePool internal pool;
    MockPoolFactory internal factory;
    DexPathRoute internal route;

    function setUp() public {
        lock = new Lock(ADAPTER, SWAP);
        usdt = new PayoutToken("USDT", 6);
        usdc = new PayoutToken("USDC", 6);
        pool = new HalmosRoutePool(address(usdt), address(usdc));
        factory = new MockPoolFactory();
        factory.register(address(pool));
        DexHop[] memory hops = new DexHop[](1);
        hops[0] =
            DexHop({kind: HopKind.ConcentratedLiquidity, pool: address(pool), tokenOut: address(usdc), i: 0, j: 0});
        route = new DexPathRoute(
            RouteConfig({
                lpVaultSwap: SWAP,
                lock: address(lock),
                aaveAdapter: ADAPTER,
                tokenIn: address(usdt),
                tokenOut: address(usdc),
                tokenClassMask: 2,
                uniswapV3Factory: address(factory),
                slipstreamFactory: address(0),
                curveFactory: address(0)
            }),
            hops
        );
    }

    function _setLock(
        uint8 state
    ) internal {
        if (state % 3 == 1) {
            vm.prank(SWAP);
            lock.acquire();
        } else if (state % 3 == 2) {
            vm.prank(ADAPTER);
            lock.acquire();
        }
    }

    function _fund(
        address from,
        uint256 amount
    ) internal {
        usdt.mint(from, amount);
        vm.prank(from);
        usdt.approve(address(route), amount);
    }

    // PROP-037 verifies: REQ-ROUTE-007, REQ-ROUTE-025, INV-054
    function check_PROP_037_swapOnlyForLPVaultSwapUnderLock(
        address caller,
        uint8 lockState,
        uint128 amountIn,
        uint128 minOut,
        uint128 poolOut
    ) public {
        _setLock(lockState);
        pool.setPayOut(poolOut);
        usdc.mint(address(pool), poolOut);
        _fund(caller, amountIn);
        vm.prank(caller);
        try route.swap(amountIn, minOut) {
            assert(caller == SWAP);
            assert(lockState % 3 != 0);
        } catch (bytes memory reason) {
            if (caller != SWAP) {
                assert(bytes4(reason) == ISettlementRoute.NotLPVaultSwap.selector);
            } else if (lockState % 3 == 0) {
                assert(bytes4(reason) == ISettlementRoute.NotLocked.selector);
            }
        }
    }

    // PROP-036 verifies: REQ-ROUTE-013, REQ-ROUTE-029, INV-040
    function check_PROP_036_callbackRefusedOutsideHop(
        address caller,
        int256 amount0,
        int256 amount1
    ) public {
        usdt.mint(address(route), 1e6);
        vm.prank(caller);
        try route.uniswapV3SwapCallback(amount0, amount1, "") {
            assert(false);
        } catch (bytes memory reason) {
            assert(bytes4(reason) == ISettlementRoute.InvalidCallback.selector);
        }
        assert(usdt.balanceOf(address(route)) == 1e6);
    }

    // PROP-036 verifies: REQ-ROUTE-013, REQ-ROUTE-029, INV-040
    function check_PROP_036_callbackPaysAtMostTheHopAmountOnce(
        uint128 amountIn,
        int136 owedRaw
    ) public {
        int256 owed = owedRaw;
        _setLock(1);
        vm.assume(owed != 0 && amountIn != 0);
        usdt.mint(address(route), 1e6); // a donation a hostile pool would like to take
        pool.setOwedOverride(owed);
        pool.setPayOut(1);
        usdc.mint(address(pool), 1);
        _fund(SWAP, amountIn);
        vm.prank(SWAP);
        try route.swap(amountIn, 1) {
            // The pool asked for a positive amount no larger than the hop's input; the donation is untouched.
            assert(owed > 0 && uint256(owed) <= amountIn);
            assert(usdt.balanceOf(address(route)) == 1e6);
        } catch (bytes memory reason) {
            assert(bytes4(reason) == ISettlementRoute.InvalidCallback.selector);
        }
    }

    // PROP-068 verifies: REQ-ROUTE-009, REQ-ROUTE-014, REQ-ROUTE-015, REQ-ROUTE-016, REQ-ROUTE-042, INV-021, INV-083
    function check_PROP_068_swapDeliversAtLeastMinOut(
        uint128 amountIn,
        uint128 minOut,
        uint128 poolOut
    ) public {
        _setLock(1);
        pool.setPayOut(poolOut);
        usdc.mint(address(pool), poolOut);
        _fund(SWAP, amountIn);
        uint256 outBefore = usdc.balanceOf(SWAP);
        vm.prank(SWAP);
        try route.swap(amountIn, minOut) returns (uint256 out) {
            assert(out >= minOut);
            assert(usdc.balanceOf(SWAP) - outBefore == out);
            assert(out == poolOut);
            assert(usdt.balanceOf(SWAP) == 0);
            assert(usdt.balanceOf(address(route)) == 0 && usdc.balanceOf(address(route)) == 0);
            assert(usdt.allowance(address(route), address(pool)) == 0);
        } catch (bytes memory reason) {
            if (amountIn == 0) {
                assert(bytes4(reason) == ISettlementRoute.TransferMismatch.selector);
            } else if (minOut == 0) {
                assert(bytes4(reason) == ISettlementRoute.ZeroMinOut.selector);
            } else {
                assert(poolOut < minOut);
                assert(
                    keccak256(reason)
                        == keccak256(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, poolOut, minOut))
                );
            }
        }
    }
}
