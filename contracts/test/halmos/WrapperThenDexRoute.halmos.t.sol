// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {WrapperThenDexRoute} from "../../src/liquidation/settlement-routes/WrapperThenDexRoute.sol";
import {DexHop, HopKind} from "../../src/liquidation/settlement-routes/types/DexHop.sol";
import {RouteConfig} from "../../src/liquidation/settlement-routes/types/RouteConfig.sol";
import {WrapperKind, WrapperStep} from "../../src/liquidation/settlement-routes/types/WrapperStep.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {HalmosRoutePool} from "../utils/mocks/HalmosRoutePool.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {MockDaiUsds, MockPoolFactory} from "../utils/mocks/SwapRouteMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @title WrapperThenDexRouteHalmosTest
/// @notice Symbolic checks of the `WrapperThenDex` swap route (USDS → DAI through the converter, then a DAI/USDC hop)
/// for every caller, Lock state, amount, minimum and pool outcome: the caller and Lock rule, the callback refused
/// outside a hop, and a completed swap delivering at least `minOut` with no balance or allowance left in the route.
/// @dev The converter is 1:1 and the pool pays a symbolic `poolOut`; amounts are bounded to uint128.
contract WrapperThenDexRouteHalmosTest is Test {
    address internal constant ADAPTER = address(0xADA9);
    address internal constant SWAP = address(0x5A9);

    Lock internal lock;
    PayoutToken internal usds;
    PayoutToken internal dai;
    PayoutToken internal usdc;
    MockDaiUsds internal converter;
    HalmosRoutePool internal pool;
    MockPoolFactory internal factory;
    WrapperThenDexRoute internal route;

    function setUp() public {
        lock = new Lock(ADAPTER, SWAP);
        usds = new PayoutToken("USDS", 18);
        dai = new PayoutToken("DAI", 18);
        usdc = new PayoutToken("USDC", 6);
        converter = new MockDaiUsds(address(usds), address(dai));
        pool = new HalmosRoutePool(address(dai), address(usdc));
        factory = new MockPoolFactory();
        factory.register(address(pool));
        DexHop[] memory hops = new DexHop[](1);
        hops[0] =
            DexHop({kind: HopKind.ConcentratedLiquidity, pool: address(pool), tokenOut: address(usdc), i: 0, j: 0});
        route = new WrapperThenDexRoute(
            RouteConfig({
                lpVaultSwap: SWAP,
                lock: address(lock),
                aaveAdapter: ADAPTER,
                tokenIn: address(usds),
                tokenOut: address(usdc),
                tokenClassMask: 2,
                uniswapV3Factory: address(factory),
                slipstreamFactory: address(0),
                curveFactory: address(0)
            }),
            WrapperStep({kind: WrapperKind.UsdsToDai, wrapper: address(converter), underlying: address(dai)}),
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
        usds.mint(from, amount);
        vm.prank(from);
        usds.approve(address(route), amount);
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
        dai.mint(address(route), 1e18);
        vm.prank(caller);
        try route.uniswapV3SwapCallback(amount0, amount1, "") {
            assert(false);
        } catch (bytes memory reason) {
            assert(bytes4(reason) == ISettlementRoute.InvalidCallback.selector);
        }
        assert(dai.balanceOf(address(route)) == 1e18);
    }

    // PROP-068 verifies: REQ-ROUTE-009, REQ-ROUTE-010, REQ-ROUTE-014, REQ-ROUTE-015, REQ-ROUTE-016, REQ-ROUTE-042, INV-021, INV-083
    function check_PROP_068_swapDeliversAtLeastMinOut(
        uint128 amountIn,
        uint128 minOut,
        uint128 poolOut
    ) public {
        _setLock(1);
        pool.setPayOut(poolOut);
        usdc.mint(address(pool), poolOut);
        _fund(SWAP, amountIn);
        vm.prank(SWAP);
        try route.swap(amountIn, minOut) returns (uint256 out) {
            assert(out >= minOut && out == poolOut);
            assert(usdc.balanceOf(SWAP) == out);
            assert(usds.balanceOf(SWAP) == 0);
            assert(usds.balanceOf(address(route)) == 0 && dai.balanceOf(address(route)) == 0);
            assert(usdc.balanceOf(address(route)) == 0);
            assert(usds.allowance(address(route), address(converter)) == 0);
        } catch (bytes memory reason) {
            if (amountIn == 0) {
                assert(bytes4(reason) == ISettlementRoute.TransferMismatch.selector);
            } else if (minOut == 0) {
                assert(bytes4(reason) == ISettlementRoute.ZeroMinOut.selector);
            } else {
                assert(
                    keccak256(reason)
                        == keccak256(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, poolOut, minOut))
                );
            }
        }
    }
}
