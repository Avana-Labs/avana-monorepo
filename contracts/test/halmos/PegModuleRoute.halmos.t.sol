// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {PegModuleRoute} from "../../src/liquidation/settlement-routes/PegModuleRoute.sol";
import {PegModuleKind, PegModuleStep} from "../../src/liquidation/settlement-routes/types/PegModuleStep.sol";
import {RouteConfig} from "../../src/liquidation/settlement-routes/types/RouteConfig.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {RouteMathHarness} from "../utils/harness/RouteMathHarness.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {MockLitePsm} from "../utils/mocks/SwapRouteMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @title PegModuleRouteHalmosTest
/// @notice Symbolic checks of the `PegModule` swap route (DAI → USDC through the LitePSM) for every caller, Lock state,
/// amount and minimum: the caller and Lock rule, the callback always refused, a completed swap delivering at least
/// `minOut` with the DAI conserved between the LitePSM and LPVaultSwap, and the gem amount of REQ-ROUTE-012 being the
/// largest the DAI buys with no overflow.
/// @dev The LitePSM fee is 0 in the swap checks and concrete (0, 1, 10 and 100 bps) in the gem-amount check; DAI
/// amounts are bounded to uint96 (79 billion DAI) so the solver handles the mulDiv; the symbolic-fee form is fuzzed.
contract PegModuleRouteHalmosTest is Test {
    address internal constant ADAPTER = address(0xADA9);
    address internal constant SWAP = address(0x5A9);

    Lock internal lock;
    PayoutToken internal dai;
    PayoutToken internal usdc;
    MockLitePsm internal psm;
    PegModuleRoute internal route;
    RouteMathHarness internal math;

    function setUp() public {
        lock = new Lock(ADAPTER, SWAP);
        dai = new PayoutToken("DAI", 18);
        usdc = new PayoutToken("USDC", 6);
        psm = new MockLitePsm(address(dai), address(usdc), 6);
        usdc.mint(address(psm), type(uint128).max);
        route = new PegModuleRoute(
            RouteConfig({
                lpVaultSwap: SWAP,
                lock: address(lock),
                aaveAdapter: ADAPTER,
                tokenIn: address(dai),
                tokenOut: address(usdc),
                tokenClassMask: 2,
                uniswapV3Factory: address(0),
                slipstreamFactory: address(0),
                curveFactory: address(0),
                curveLegacyPools: new address[](0)
            }),
            PegModuleStep({
                kind: PegModuleKind.LitePsm, module: address(psm), wrapper: address(0), intermediate: address(0)
            })
        );
        math = new RouteMathHarness();
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
        dai.mint(from, amount);
        vm.prank(from);
        dai.approve(address(route), amount);
    }

    // PROP-037 verifies: REQ-ROUTE-007, REQ-ROUTE-025, INV-054
    function check_PROP_037_swapOnlyForLPVaultSwapUnderLock(
        address caller,
        uint8 lockState,
        uint128 amountIn,
        uint128 minOut
    ) public {
        _setLock(lockState);
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
    function check_PROP_036_callbackAlwaysRefused(
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

    // PROP-068 verifies: REQ-ROUTE-009, REQ-ROUTE-012, REQ-ROUTE-014, REQ-ROUTE-015, REQ-ROUTE-016, REQ-ROUTE-042, INV-021, INV-083
    function check_PROP_068_swapDeliversAtLeastMinOut(
        uint96 amountIn,
        uint128 minOut
    ) public {
        _setLock(1);
        _fund(SWAP, amountIn);
        vm.prank(SWAP);
        try route.swap(amountIn, minOut) returns (uint256 out) {
            assert(out >= minOut);
            assert(usdc.balanceOf(SWAP) == out);
            // At tout = 0 the LitePSM takes out × 10¹² DAI and the rest (below one USDC unit) comes back.
            assert(dai.balanceOf(SWAP) == amountIn - out * 1e12);
            assert(dai.balanceOf(SWAP) < 1e12);
            assert(dai.balanceOf(address(route)) == 0 && usdc.balanceOf(address(route)) == 0);
            assert(dai.allowance(address(route), address(psm)) == 0);
        } catch (bytes memory reason) {
            if (amountIn == 0) {
                assert(bytes4(reason) == ISettlementRoute.TransferMismatch.selector);
            } else if (minOut == 0) {
                assert(bytes4(reason) == ISettlementRoute.ZeroMinOut.selector);
            } else {
                uint256 gem = amountIn / 1e12;
                assert(
                    keccak256(reason)
                        == keccak256(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, gem, minOut))
                );
            }
        }
    }

    // PROP-044 verifies: REQ-ROUTE-012
    function check_PROP_044_litePsmGemAmtLargestNoOverflow(
        uint96 dai_,
        uint8 feeCase
    ) public view {
        // Concrete fees: 0, 1 bp, 10 bps, 100 bps (the symbolic-fee form is fuzzed in RouteMath.fuzz).
        uint256 tout = feeCase % 4 == 0 ? 0 : (feeCase % 4 == 1 ? 1e14 : (feeCase % 4 == 2 ? 1e15 : 1e16));
        uint256 g = math.litePsmGemAmt(dai_, tout, 1e12);
        assert(math.litePsmCost(g, tout, 1e12) <= dai_);
        assert(math.litePsmCost(g + 1, tout, 1e12) > dai_);
    }
}
