// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DexPathRoute} from "../../../src/liquidation/settlement-routes/DexPathRoute.sol";
import {PayoutToken} from "../../utils/mocks/PayoutToken.sol";
import {MockCLPool, MockCurvePool, MockRouteCaller} from "../../utils/mocks/SwapRouteMocks.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title DexPathRouteHandler
/// @notice Drives one two-hop route (cbETH →(concentrated) WETH →(Curve) USDC) through swaps of random size under the
/// Lock, pool rate moves, a concentrated pool that runs out of liquidity at the price limit, a transfer fee switched on
/// the debt asset, and donations of every path token to the route. Ghosts record the donations (the only balance the
/// route may hold), every swap whose returned output differs from LPVaultSwap's measured rise, and every swap that
/// moved LPVaultSwap's input by other than the measured input less the residue it got back.
contract DexPathRouteHandler is CommonBase, StdUtils {
    DexPathRoute public immutable ROUTE;
    MockRouteCaller public immutable SWAPPER;
    MockCLPool public immutable P1;
    MockCurvePool public immutable P2;
    PayoutToken public immutable CBETH;
    PayoutToken public immutable WETH;
    PayoutToken public immutable USDC;

    mapping(address token => uint256 amount) public donated;
    uint256 public outMismatches;
    uint256 public inputMismatches;
    uint256 public swaps;
    uint256 public failedSwaps;

    constructor(
        DexPathRoute route,
        MockRouteCaller swapper,
        MockCLPool p1,
        MockCurvePool p2,
        PayoutToken cbeth,
        PayoutToken weth,
        PayoutToken usdc
    ) {
        (ROUTE, SWAPPER, P1, P2) = (route, swapper, p1, p2);
        (CBETH, WETH, USDC) = (cbeth, weth, usdc);
    }

    /// @notice LPVaultSwap swaps 10^12 to 10^22 cbETH with a minimum of one unit.
    function swap(
        uint256 amountIn
    ) external {
        amountIn = bound(amountIn, 1e12, 1e22);
        CBETH.mint(address(SWAPPER), amountIn);
        uint256 inBefore = CBETH.balanceOf(address(SWAPPER));
        uint256 outBefore = USDC.balanceOf(address(SWAPPER));
        try SWAPPER.swapUnderLock(ROUTE, amountIn, 1) returns (uint256 out) {
            ++swaps;
            if (USDC.balanceOf(address(SWAPPER)) - outBefore != out) ++outMismatches;
            // The residue is the cbETH the thin pool did not take; LPVaultSwap's spend is what the pool kept.
            uint256 spent = inBefore - CBETH.balanceOf(address(SWAPPER));
            if (spent > amountIn) ++inputMismatches;
        } catch {
            ++failedSwaps;
            // A reverted swap leaves the input with LPVaultSwap.
            if (CBETH.balanceOf(address(SWAPPER)) != inBefore) ++inputMismatches;
        }
    }

    /// @notice The concentrated pool's rate moves within 0.5 to 2 WETH per cbETH, or to 0.
    function setRate1(
        uint256 num
    ) external {
        P1.setRate(bound(num, 0, 2000), 1000);
    }

    /// @notice The Curve pool's rate moves within 0 to 4,000 USDC per WETH.
    function setRate2(
        uint256 num
    ) external {
        P2.setRate(bound(num, 0, 4000e6), 1e18);
    }

    /// @notice The concentrated pool takes at most 10^12 to 10^22 cbETH per swap (out of liquidity at the limit).
    function setMaxIn(
        uint256 maxIn
    ) external {
        P1.setMaxIn(bound(maxIn, 1e12, 1e22));
    }

    /// @notice The debt asset's issuer switches a fee of 0 to 100 bps.
    function setOutputFee(
        uint256 bps
    ) external {
        USDC.setFeeBps(bound(bps, 0, 100));
    }

    /// @notice Anyone sends one of the path tokens to the route.
    function donate(
        uint256 which,
        uint256 amount
    ) external {
        PayoutToken t = which % 3 == 0 ? CBETH : which % 3 == 1 ? WETH : USDC;
        amount = bound(amount, 1, 1e18);
        t.mint(address(this), amount);
        uint256 before = t.balanceOf(address(ROUTE));
        t.transfer(address(ROUTE), amount);
        donated[address(t)] += t.balanceOf(address(ROUTE)) - before;
    }
}
